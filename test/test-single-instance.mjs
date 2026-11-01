/**
 * 单实例锁测试。
 *
 * 背景:多个 DSH 实例(不同 profile)会各自拉起一个剪贴板 watcher,
 * 而它们共用同一个 %TEMP%\dsh-capture 和同一个系统剪贴板 ——
 * 用户复制一次图,桌面上会弹出两个一模一样的窗口。
 *
 * 这里锁住三件容易写错的事:
 *  1. 第一个实例拿得到锁,第二个拿不到(并且**不** spawn 助手);
 *  2. 持有者进程死了,锁能自动接管(强杀会留下锁文件);
 *  3. 停掉之后锁释放,别的实例能接着拿。
 */
import { ClipboardWatcher } from "../clipboard.mjs";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const results = [];
const check = (name, ok, detail = "") => {
  results.push({ name, ok, detail });
  console.log(`${ok ? "OK  " : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
};

// 锁在 homedir 下,不在 tmpdir 下 —— 后者每个 shell 可能是不同的私有目录,
// 放那里两个 DSH 实例会各锁各的(见 clipboard.mjs 里 LOCK_PATH 的注释)。
const LOCK = join(homedir(), ".dsh", "dsh-screenshot-capture", "watcher.lock");

/** 每个用例都从干净状态开始,否则前一个的锁会污染后一个。 */
function resetLock() {
  try { unlinkSync(LOCK); } catch { /* 本来就没有 */ }
}

// ---- 用例 1:两个实例,第二个必须让位 ----
resetLock();
{
  const a = new ClipboardWatcher({ pollIntervalMs: 200, dialog: {} });
  const aEvents = [];
  a.on("busy", (ev) => aEvents.push(ev.msg));
  // 手动只跑抢锁这一步,不 spawn。
  const gotA = a.__testAcquire();
  check("第一个实例拿到锁", gotA === true, `acquire=${gotA}`);
  check("锁文件写入了自己的 PID", existsSync(LOCK) && readFileSync(LOCK, "utf8").trim() === String(process.pid),
    existsSync(LOCK) ? `pid=${readFileSync(LOCK, "utf8").trim()}` : "锁文件不存在");

  const b = new ClipboardWatcher({ pollIntervalMs: 200, dialog: {} });
  const bEvents = [];
  b.on("busy", (ev) => bEvents.push(ev.msg));
  const gotB = b.__testAcquire();
  check("第二个实例抢不到锁", gotB === false, `acquire=${gotB}`);
  check("第二个实例不会覆盖锁里的 PID",
    readFileSync(LOCK, "utf8").trim() === String(process.pid), "PID 未变");

  a.__testRelease();
  check("第一个实例释放后锁文件消失", !existsSync(LOCK), "已删除");

  const gotB2 = b.__testAcquire();
  check("释放后第二个实例能拿到", gotB2 === true, `acquire=${gotB2}`);
  b.__testRelease();
}

// ---- 用例 2:持有者已死,锁要被接管 ----
resetLock();
{
  // 造一个「几乎不可能存在的 PID」当僵尸持有者。
  // Windows 上进程号是 4 的倍数且不会到这个量级。
  writeFileSync(LOCK, "999999996", "utf8");
  const c = new ClipboardWatcher({ pollIntervalMs: 200, dialog: {} });
  const got = c.__testAcquire();
  check("僵尸锁(持有者已死)能被接管", got === true, `acquire=${got}`);
  check("接管后锁里是自己的 PID", readFileSync(LOCK, "utf8").trim() === String(process.pid), "已改写");
  c.__testRelease();
}

// ---- 用例 3:锁文件内容不是数字(损坏),也要能接管 ----
resetLock();
{
  writeFileSync(LOCK, "not-a-pid", "utf8");
  const d = new ClipboardWatcher({ pollIntervalMs: 200, dialog: {} });
  const got = d.__testAcquire();
  check("损坏的锁文件能被接管", got === true, `acquire=${got}`);
  d.__testRelease();
}

// ---- 用例 4:stop() 之后锁必须释放,否则本实例重载后自己都起不来 ----
resetLock();
{
  const e = new ClipboardWatcher({ pollIntervalMs: 200, dialog: {} });
  e.__testAcquire();
  check("stop 前锁在", existsSync(LOCK), "");
  e.stop();
  check("stop() 之后锁已释放", !existsSync(LOCK), "");
}

resetLock();

const failed = results.filter((r) => !r.ok);
console.log(`\n[lock-test] ${results.length - failed.length}/${results.length} 通过`);
if (failed.length) {
  for (const f of failed) console.log(`  失败:${f.name} ${f.detail}`);
  process.exit(1);
}
