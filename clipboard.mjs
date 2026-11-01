import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { homedir, tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

/**
 * 进程还活着吗?`process.kill(pid, 0)` 只探活不真发信号。
 * Windows 上对**存在但无权限**的进程会抛 EPERM —— 那也是活着,不能当僵尸清掉。
 */
function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === "EPERM";
  }
}

const __dirname = fileURLToPath(new URL(".", import.meta.url));
const PS_SCRIPT = join(__dirname, "scripts", "clip-dialog.ps1");
const POWERSHELL = join(
  process.env.SystemRoot || "C:\\Windows",
  "System32",
  "WindowsPowerShell",
  "v1.0",
  "powershell.exe",
);

/**
 * 单实例锁的落点。
 *
 * **不能用 `tmpdir()`** —— 实测踩过:从 shell 里起的 DSH 会继承那个 shell 的
 * 私有 TEMP(`...\Temp\dsh-win-bash-<pid>-<rand>`),于是两个 DSH 实例算出来的
 * `tmpdir()` 根本不是同一个目录,锁文件各写各的,锁形同虚设。
 * `homedir()`(`USERPROFILE`)对所有实例都是同一个,才是能共享的位置。
 */
const LOCK_DIR = join(homedir(), ".dsh", "dsh-screenshot-capture");
const LOCK_PATH = join(LOCK_DIR, "watcher.lock");

/**
 * 剪贴板监听器:拉起常驻 PowerShell 助手(轮询剪贴板 + 系统级悬浮窗),
 * 通过事件日志文件(events.log, JSON 每行)通信,避免管道依赖。
 * 事件: "ready" | "img" | "choice" | "err" | "exit"
 */
export class ClipboardWatcher extends EventEmitter {
  constructor(config = {}, options = {}) {
    super();
    this.config = config;
    this.autoAction = options.autoAction || "";
    this.workDir = join(tmpdir(), "dsh-capture");
    this.logPath = join(this.workDir, "events.log");
    // 单实例锁:多个 DSH 实例(不同 profile)会各自拉起一个 watcher,
    // 而它们共用同一个系统剪贴板 —— 一次复制就会弹出**多个**一模一样的窗口。
    // 锁放在 homedir 下(不是 tmpdir,原因见 LOCK_PATH 的注释)。
    this.lockDir = LOCK_DIR;
    this.lockPath = LOCK_PATH;
    this.lockHeld = false;
    this.offset = 0;
    this.child = null;
    this.timer = null;
    this.started = false;
  }

  /**
   * 抢单实例锁。抢到返回 true;已被别的**活进程**占着返回 false。
   * 上一个持有者被强杀时锁文件会留下,所以读到 PID 要先探活,死了就接管。
   */
  #acquireLock() {
    mkdirSync(this.lockDir, { recursive: true });
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        closeSync(openSync(this.lockPath, "wx")); // wx = 已存在则失败,原子
        writeFileSync(this.lockPath, String(process.pid), "utf8");
        this.lockHeld = true;
        return true;
      } catch (err) {
        if (err.code !== "EEXIST") {
          // 锁文件本身读不了(权限/目录被占),不因此拒绝服务,当作无锁继续。
          this.lockHeld = false;
          return true;
        }
      }
      let holder = NaN;
      try {
        holder = Number.parseInt(readFileSync(this.lockPath, "utf8").trim(), 10);
      } catch { /* 读不到就当僵尸 */ }
      if (pidAlive(holder)) return false; // 真有人在听,让给它
      try { unlinkSync(this.lockPath); } catch { /* 别人抢先删了也无妨 */ }
    }
    return false;
  }

  #releaseLock() {
    if (!this.lockHeld) return;
    this.lockHeld = false;
    try {
      // 只删自己的锁,别把别人刚接管的删掉。
      const holder = Number.parseInt(readFileSync(this.lockPath, "utf8").trim(), 10);
      if (holder === process.pid) unlinkSync(this.lockPath);
    } catch { /* 已经没了 */ }
  }

  /**
   * 只跑抢锁/放锁,不 spawn 助手 —— 给测试用。
   * 生产路径不经过这里,start() 内部会自己调;单独暴露是因为
   * 「两个实例会不会都弹窗」这件事不值得为它真起一个 PowerShell。
   */
  __testAcquire() {
    return this.#acquireLock();
  }

  __testRelease() {
    this.#releaseLock();
  }

  /**
   * 把配置摊平成助手脚本认的那份 JSON,写到 workDir/watcher-config.json。
   *
   * 单独抽出来是为了能测:start() 会 spawn powershell,而「字段有没有漏传」
   * 只需要这一步。之前测这条链要真起一个进程,测完还得收拾,很容易测了个寂寞。
   * @returns 写出的配置对象(方便测试直接断言,不用再读文件)。
   */
  writeWatcherConfig() {
    const flat = {
      pollIntervalMs: this.config.pollIntervalMs ?? 200,
      cooldownMs: this.config.cooldownMs ?? 2000,
      // 悬浮窗位置:跟随鼠标(cursor)还是钉在固定屏幕坐标(fixed)。
      positionMode: this.config.dialog?.positionMode ?? "cursor",
      fixedX: this.config.dialog?.fixedX ?? 0,
      fixedY: this.config.dialog?.fixedY ?? 0,
      offsetX: this.config.dialog?.offsetX ?? 16,
      offsetY: this.config.dialog?.offsetY ?? 16,
      previewMaxWidth: this.config.dialog?.previewMaxWidth ?? 320,
      // 固定尺寸,0 = 按内容自适应
      width: this.config.dialog?.width ?? 0,
      height: this.config.dialog?.height ?? 0,
      // 同一屏被剪贴板写两遍时的去重窗口(秒级);0 = 不去重
      dupWindowMs: this.config.dupWindowMs ?? 6000,
      // 悬浮窗自动关闭秒数;0 = 一直等用户点
      autoCloseSec: this.config.dialog?.autoCloseSec ?? 0,
    };
    mkdirSync(this.workDir, { recursive: true });
    writeFileSync(join(this.workDir, "watcher-config.json"), JSON.stringify(flat), "utf8");
    return flat;
  }

  start() {
    if (this.started) return;
    this.started = true;

    if (!this.#acquireLock()) {
      this.started = false;
      this.emit("busy", {
        msg: "另一个 DSH 实例已在监听剪贴板,本实例不再重复弹窗",
      });
      return;
    }

    mkdirSync(this.workDir, { recursive: true });
    if (existsSync(this.logPath)) this.offset = statSync(this.logPath).size;
    else this.offset = 0;

    const cfgFile = join(this.workDir, "watcher-config.json");
    this.writeWatcherConfig();

    const args = [
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", PS_SCRIPT,
      "-ConfigPath", cfgFile,
    ];
    if (this.autoAction) args.push("-AutoAction", this.autoAction);

    try {
      this.child = spawn(POWERSHELL, args, {
        stdio: "ignore",
        windowsHide: true,
      });
    } catch (err) {
      this.emit("err", { msg: `spawn powershell: ${err.message}` });
      this.#releaseLock();
      return;
    }

    this.child.on("exit", (code) => {
      this.#releaseLock();
      this.emit("exit", { code });
      this.started = false;
      this.child = null;
    });

    this.timer = setInterval(() => this.#tick(), 300);
    this.timer.unref?.();
  }

  /** 同步停(用于插件卸载,不等待退出)。 */
  stop() {
    if (this.timer) { clearInterval(this.timer); this.timer = null; }
    if (this.child) {
      try { this.child.kill(); } catch { /* ignore */ }
      this.child = null;
    }
    this.#releaseLock();
    this.started = false;
  }

  /**
   * 异步停:等 PowerShell 子进程真正退出后再 resolve,避免旧监听残留。
   * kill() 之外再用 taskkill /T /F 强杀进程树,并带超时兜底。
   * @param timeoutMs - 等待退出的上限(默认 3s)。
   */
  stopAsync(timeoutMs = 3000) {
    if (this.timer) { clearInterval(this.timer); this.timer = null; }
    this.started = false;
    const child = this.child;
    this.child = null;
    this.#releaseLock();
    if (!child || child.exitCode !== null) return Promise.resolve();
    return new Promise((resolve) => {
      let settled = false;
      const done = () => {
        if (settled) return;
        settled = true;
        resolve();
      };
      const guard = setTimeout(done, timeoutMs);
      child.once("exit", () => {
        clearTimeout(guard);
        done();
      });
      try {
        child.kill();
      } catch { /* 继续走 taskkill 兜底 */ }
      // Windows 兜底:强制终止进程树(子进程可能处于 Add-Type 初始化等状态)
      try {
        const killer = spawn("taskkill", ["/PID", String(child.pid), "/T", "/F"], {
          stdio: "ignore",
          windowsHide: true,
        });
        killer.unref?.();
      } catch { /* ignore */ }
    });
  }

  #tick() {
    if (!existsSync(this.logPath)) return;
    const size = statSync(this.logPath).size;
    if (size <= this.offset) return;
    let buf;
    try {
      const fd = readFileSync(this.logPath);
      buf = fd.subarray(this.offset, size);
    } catch {
      return;
    }
    this.offset = size;
    const lines = buf.toString("utf8").split(/\r?\n/).filter(Boolean);
    for (const line of lines) {
      let ev;
      try { ev = JSON.parse(line); } catch { continue; }
      this.emit(ev.t, ev);
    }
  }
}
