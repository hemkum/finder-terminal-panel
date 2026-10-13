#!/usr/bin/osascript -l JavaScript
// finder-terminal watcher (JXA). One long-running process, no per-tick spawns.
//   fast timer (50 ms):  frontmost app -> float the panel only while Finder/Ghostty is in front
//   slow timer (500 ms): Finder's active-tab folder -> follow file; Ghostty window still alive?
// Usage: finder-terminal-watch.js GID FOLLOW_FILE STATE_DIR LOG LAUNCHER FLOAT_MANAGED(0|1) FLOAT_MODE(auto|on|off)
ObjC.import('AppKit');
ObjC.import('Foundation');
ObjC.import('stdlib');

const FINDER = 'com.apple.finder', GHOSTTY = 'com.mitchellh.ghostty';
const argv = $.NSProcessInfo.processInfo.arguments;
const A = [];
for (let i = 0; i < argv.count; i++) A.push(ObjC.unwrap(argv.objectAtIndex(i)));
// osascript puts script args after the script path
const scriptIdx = A.findIndex(a => a.endsWith('finder-terminal-watch.js'));
const args = A.slice(scriptIdx + 1);
if (args.length < 7) { console.log('usage: GID FOLLOW_FILE STATE_DIR LOG LAUNCHER FLOAT_MANAGED FLOAT_MODE'); $.exit(2); }
const [GID, FOLLOW_FILE, STATE_DIR, LOG, LAUNCHER, FLOAT_MANAGED, FLOAT_MODE] = args;
const PID_FILE = STATE_DIR + '/watcher.pid';
const FLOAT_FILE = STATE_DIR + '/floating';
const PID = $.NSProcessInfo.processInfo.processIdentifier;
const fm = $.NSFileManager.defaultManager;
const shell = Application.currentApplication(); shell.includeStandardAdditions = true;

function nsstr(s) { return $.NSString.stringWithUTF8String(s); }
function readFile(p) { const s = $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null); return s.isNil() ? null : ObjC.unwrap(s); }
function writeFile(p, s) { nsstr(s + '\n').writeToFileAtomicallyEncodingError(p, true, $.NSUTF8StringEncoding, null); }
function removeFile(p) { fm.removeItemAtPathError(p, null); }
function log(msg) {
  const d = $.NSDateFormatter.alloc.init; d.dateFormat = 'yyyy-MM-dd HH:mm:ss.SSS';
  const line = ObjC.unwrap(d.stringFromDate($.NSDate.date)) + ' [' + PID + '] ' + msg + '\n';
  const fh = $.NSFileHandle.fileHandleForWritingAtPath(LOG);
  if (fh.isNil()) return;
  fh.seekToEndOfFile; fh.writeData(nsstr(line).dataUsingEncoding($.NSUTF8StringEncoding)); fh.closeFile;
}
function isDir(p) { const d = Ref(); return fm.fileExistsAtPathIsDirectory(p, d) && d[0]; }

let ghostty = null;
function ghosttyApp() { if (!ghostty) ghostty = Application('Ghostty'); return ghostty; }
function panelWindow() { return ghosttyApp().windows.byId(GID); }
function panelAlive() {
  try { return ghosttyApp().running() && panelWindow().exists(); } catch (e) { return false; }
}
function toggleFloat() {
  try { ghosttyApp().performAction('toggle_window_float_on_top', { on: panelWindow().selectedTab().focusedTerminal() }); return true; }
  catch (e) { log('toggle float failed: ' + e); return false; }
}
function stageManagerOn() {
  try { return $.NSUserDefaults.alloc.initWithSuiteName('com.apple.WindowManager').boolForKey('GloballyEnabled'); } catch (e) { return false; }
}
function finderFolder() {
  try {
    const u = Application('Finder').finderWindows[0].target().url();
    if (typeof u !== 'string' || !u.startsWith('file://')) return null;
    let p = decodeURIComponent(u.slice(7)).replace(/\/+$/, '');
    if (p === '') p = '/';
    return isDir(p) ? p : null;
  } catch (e) { return null; }
}
function frontBundle() {
  const a = $.NSWorkspace.sharedWorkspace.frontmostApplication;
  return a.isNil() ? '' : ObjC.unwrap(a.bundleIdentifier) || '';
}
function finish(reason) {
  log(reason + '; exiting');
  try { shell.doShellScript("'" + LAUNCHER.replace(/'/g, "'\\''") + "' _cleanup " + PID); } catch (e) { log('cleanup failed: ' + e); }
  $.exit(0);
}

let manageFloat = FLOAT_MANAGED === '1';
let floating = manageFloat;        // the launcher floats the panel before starting us
let lastFolder = null, lastFront = '', ticks = 0;

ObjC.registerSubclass({
  name: 'FTWatcher',
  methods: {
    'fast:': { types: ['void', ['id']], implementation: function (t) {
      if (!manageFloat) return;
      const front = frontBundle();
      if (front === '' || front === lastFront) return;
      lastFront = front;
      const ours = (front === FINDER || front === GHOSTTY);
      if (ours && !floating) { if (toggleFloat()) { floating = true; writeFile(FLOAT_FILE, '1'); log('panel shown (front=' + front + ')'); } }
      else if (!ours && floating) { if (toggleFloat()) { floating = false; removeFile(FLOAT_FILE); log('panel parked (front=' + front + ')'); } }
    } },
    'slow:': { types: ['void', ['id']], implementation: function (t) {
      ticks++;
      const pid = readFile(PID_FILE);
      if (pid === null || parseInt(pid, 10) !== PID) { log('watcher replaced'); $.exit(0); }
      if (!panelAlive()) finish('Ghostty window ' + GID + ' is gone');
      const p = finderFolder();
      if (p !== null && p !== lastFolder) { writeFile(FOLLOW_FILE, p); lastFolder = p; log('finder -> ' + p); }
      if (FLOAT_MODE === 'auto' && ticks % 4 === 0) {           // every 2 s: follow Stage Manager on/off
        const sm = stageManagerOn();
        if (sm && !manageFloat) { manageFloat = true; floating = false; lastFront = ''; log('Stage Manager on: managing float'); }
        else if (!sm && manageFloat) { if (floating && toggleFloat()) floating = false; manageFloat = false; removeFile(FLOAT_FILE); log('Stage Manager off: float dropped'); }
      }
    } }
  }
});

const w = $.FTWatcher.alloc.init;
log('watcher started for Ghostty window ' + GID + ' (float ' + (manageFloat ? 'managed' : 'off') + ')');
$.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(0.05, w, 'fast:', null, true);
$.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(0.5, w, 'slow:', null, true);
$.NSRunLoop.currentRunLoop.run;
