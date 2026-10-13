// finder-terminal watcher (Swift, event-driven). Built by install.sh when swiftc is
// available; otherwise bin/finder-terminal-watch.js (JXA, polling) is used.
//
//   NSWorkspace activation events  -> float/park the panel under Stage Manager (no polling)
//   Finder Accessibility events    -> read the active tab's folder only when Finder changed it
//   Ghostty window destroyed event -> restore Finder immediately when the panel is closed by hand
//   2 s safety timer               -> pidfile, Stage Manager on/off, panel alive, folder re-check
//
// Usage: finder-terminal-watch GID FOLLOW_FILE STATE_DIR LOG LAUNCHER FLOAT_MANAGED(0|1) FLOAT_MODE(auto|on|off)
import AppKit
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 8 else {
  FileHandle.standardError.write("usage: GID FOLLOW_FILE STATE_DIR LOG LAUNCHER FLOAT_MANAGED FLOAT_MODE\n".data(using: .utf8)!)
  exit(2)
}
let GID = args[1], FOLLOW_FILE = args[2], STATE_DIR = args[3], LOG = args[4], LAUNCHER = args[5]
let FLOAT_MODE = args[7]
let PID_FILE = STATE_DIR + "/watcher.pid", FLOAT_FILE = STATE_DIR + "/floating"
let PID = ProcessInfo.processInfo.processIdentifier
let FINDER = "com.apple.finder", GHOSTTY = "com.mitchellh.ghostty"
let fm = FileManager.default

// ---------------------------------------------------------------- files / log
let stamp: DateFormatter = { let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return d }()
func log(_ msg: String) {
  let line = "\(stamp.string(from: Date())) [\(PID)] \(msg)\n"
  if let h = FileHandle(forWritingAtPath: LOG) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
}
func readFile(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }
func writeFile(_ p: String, _ s: String) { try? (s + "\n").write(toFile: p, atomically: true, encoding: .utf8) }
func removeFile(_ p: String) { try? fm.removeItem(atPath: p) }
func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }

// ---------------------------------------------------------------- Apple events
// Raw Apple events. (NSAppleScript would load the whole script engine, ~30 MB.)
func cc(_ s: String) -> OSType { s.utf8.reduce(0) { $0 << 8 | OSType($1) } }
let nullDesc = NSAppleEventDescriptor.null()
func specifier(want: String, form: String, seld: NSAppleEventDescriptor, from: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
  let r = NSAppleEventDescriptor.record()
  r.setDescriptor(NSAppleEventDescriptor(typeCode: cc(want)), forKeyword: cc("want"))
  r.setDescriptor(from, forKeyword: cc("from"))
  r.setDescriptor(NSAppleEventDescriptor(enumCode: cc(form)), forKeyword: cc("form"))
  r.setDescriptor(seld, forKeyword: cc("seld"))
  return r.coerce(toDescriptorType: cc("obj "))!
}
func prop(_ code: String, of from: NSAppleEventDescriptor) -> NSAppleEventDescriptor { specifier(want: "prop", form: "prop", seld: NSAppleEventDescriptor(typeCode: cc(code)), from: from) }
func first(_ cls: String) -> NSAppleEventDescriptor { specifier(want: cls, form: "indx", seld: NSAppleEventDescriptor(int32: 1), from: nullDesc) }
func byId(_ cls: String, _ id: String) -> NSAppleEventDescriptor { specifier(want: cls, form: "ID  ", seld: NSAppleEventDescriptor(string: id), from: nullDesc) }
func send(_ cls: String, _ id: String, to bundle: String, direct: NSAppleEventDescriptor?, params: [String: NSAppleEventDescriptor] = [:]) -> NSAppleEventDescriptor? {
  let ev = NSAppleEventDescriptor(eventClass: cc(cls), eventID: cc(id), targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundle),
                                  returnID: Int16(kAutoGenerateReturnID), transactionID: Int32(kAnyTransactionID))
  if let d = direct { ev.setParam(d, forKeyword: keyDirectObject) }
  for (k, v) in params { ev.setParam(v, forKeyword: cc(k)) }
  guard let reply = try? ev.sendEvent(options: [.waitForReply, .neverInteract], timeout: 2.0) else { return nil }
  if let e = reply.paramDescriptor(forKeyword: keyErrorNumber), e.int32Value != 0 { return nil }
  return reply.paramDescriptor(forKeyword: keyDirectObject) ?? NSAppleEventDescriptor.null()
}
func getData(_ spec: NSAppleEventDescriptor, from bundle: String) -> NSAppleEventDescriptor? { send("core", "getd", to: bundle, direct: spec) }
let panelSpec = byId("Gwnd", GID)
let panelTerminal = prop("GTfT", of: prop("GWsT", of: panelSpec))                  // focused terminal of selected tab
let finderTargetURL = prop("pURL", of: prop("fvtg", of: first("brow")))          // URL of target of Finder window 1

func running(_ bundle: String) -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first }
func panelAlive() -> Bool {
  guard running(GHOSTTY) != nil, let r = send("core", "doex", to: GHOSTTY, direct: panelSpec) else { return false }
  return r.booleanValue
}
func panelName() -> String { (running(GHOSTTY) != nil ? getData(prop("pnam", of: panelSpec), from: GHOSTTY)?.stringValue : nil) ?? "" }
func toggleFloat() -> Bool {
  running(GHOSTTY) != nil && send("Ghst", "PfAc", to: GHOSTTY, direct: NSAppleEventDescriptor(string: "toggle_window_float_on_top"), params: ["GonT": panelTerminal]) != nil
}
func finderFolder() -> String? {
  guard let s = getData(finderTargetURL, from: FINDER)?.stringValue, let u = URL(string: s), u.isFileURL else { return nil }
  var p = u.path; while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
  return isDir(p) ? p : nil
}
func stageManagerOn() -> Bool { UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false }
func frontBundle() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }

// ---------------------------------------------------------------- state
var manageFloat = args[6] == "1"
var floating = manageFloat                       // the launcher floats the panel before starting us
var lastFront = ""
var lastFolder: String? = nil
var finishing = false

func finish(_ reason: String) {
  if finishing { return }; finishing = true
  log("\(reason); exiting")
  let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = [LAUNCHER, "_cleanup", "\(PID)"]
  try? p.run(); p.waitUntilExit()
  exit(0)
}

// The panel shell publishes its PID; SIGALRM makes it pull the folder now instead of on
// its next TMOUT tick. Only signal a zsh whose parent is Ghostty: a stale PID file must
// never hit a recycled PID (SIGALRM kills a process that doesn't trap it).
func procInfo(_ pid: Int32) -> (comm: String, ppid: Int32)? {
  var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
  let comm = withUnsafePointer(to: &info.kp_proc.p_comm) { $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) } }
  return (comm, info.kp_eproc.e_ppid)
}
func isPanelShell(_ pid: Int32) -> Bool {               // a zsh whose ancestor (<= 3 up, Ghostty uses login(1)) is Ghostty
  guard let g = running(GHOSTTY), let me = procInfo(pid), me.comm.hasSuffix("zsh") else { return false }
  var p = me.ppid
  for _ in 0..<3 { if p == g.processIdentifier { return true }; guard p > 1, let i = procInfo(p) else { return false }; p = i.ppid }
  return false
}
func nudgeShell() {
  if let s = readFile(FOLLOW_FILE + ".pid"), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, isPanelShell(pid) { kill(pid, SIGALRM) }
}
func syncFolder() {
  guard let p = finderFolder(), p != lastFolder else { return }
  writeFile(FOLLOW_FILE, p); lastFolder = p; log("finder -> \(p)"); nudgeShell()
}
var pendingRead: DispatchWorkItem?
func scheduleFolderRead() {                      // debounce bursts of AX events
  pendingRead?.cancel()
  let w = DispatchWorkItem { syncFolder() }
  pendingRead = w
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
}

func onFront(_ bundle: String) {
  guard manageFloat, bundle != "", bundle != lastFront else { return }
  lastFront = bundle
  let ours = bundle == FINDER || bundle == GHOSTTY
  if ours && !floating { if toggleFloat() { floating = true; writeFile(FLOAT_FILE, "1"); log("panel shown (front=\(bundle))") } }
  else if !ours && floating { if toggleFloat() { floating = false; removeFile(FLOAT_FILE); log("panel parked (front=\(bundle))") } }
}

// ---------------------------------------------------------------- events
let nc = NSWorkspace.shared.notificationCenter
nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
  onFront((n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? "")
}
nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
  if (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == GHOSTTY { finish("Ghostty quit") }
}

var finderObserver: AXObserver?
var ghosttyObserver: AXObserver?
let finderCallback: AXObserverCallback = { _, _, _, _ in scheduleFolderRead() }
let ghosttyCallback: AXObserverCallback = { _, _, notif, _ in
  if notif as String == kAXUIElementDestroyedNotification { DispatchQueue.main.async { if !panelAlive() { finish("Ghostty window \(GID) closed") } } }
}
func watchFinder() {
  guard let f = running(FINDER), AXObserverCreate(f.processIdentifier, finderCallback, &finderObserver) == .success, let obs = finderObserver else { log("Finder AX observer unavailable; folder polling only"); return }
  let app = AXUIElementCreateApplication(f.processIdentifier)
  for n in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
    AXObserverAddNotification(obs, app, n as CFString, nil)
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
}
func watchPanelWindow() {
  guard let g = running(GHOSTTY), AXObserverCreate(g.processIdentifier, ghosttyCallback, &ghosttyObserver) == .success, let obs = ghosttyObserver else { return }
  let app = AXUIElementCreateApplication(g.processIdentifier)
  var wins: AnyObject?
  guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success, let list = wins as? [AXUIElement] else { return }
  let name = panelName()
  var target: AXUIElement? = nil
  for w in list {
    var t: AnyObject?; AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
    if name != "" && (t as? String) == name { target = w; break }
  }
  if target == nil, let first = list.first { target = first }     // the panel is Ghostty's front window at start
  guard let win = target else { return }
  AXObserverAddNotification(obs, win, kAXUIElementDestroyedNotification as CFString, nil)
  CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
}

// ---------------------------------------------------------------- safety timer
var ticks = 0
let timer = Timer(timeInterval: 2.0, repeats: true) { _ in
  ticks += 1
  if let pid = readFile(PID_FILE).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), pid != PID { log("watcher replaced"); exit(0) }
  if !panelAlive() { finish("Ghostty window \(GID) is gone") }
  syncFolder()
  if FLOAT_MODE == "auto" {
    let sm = stageManagerOn()
    if sm && !manageFloat { manageFloat = true; floating = false; lastFront = ""; log("Stage Manager on: managing float"); onFront(frontBundle()) }
    else if !sm && manageFloat { if floating && toggleFloat() { floating = false }; manageFloat = false; removeFile(FLOAT_FILE); log("Stage Manager off: float dropped") }
  }
}
RunLoop.main.add(timer, forMode: .default)

log("watcher started for Ghostty window \(GID) (float \(manageFloat ? "managed" : "off"), event-driven)")
watchFinder()
watchPanelWindow()
syncFolder()
onFront(frontBundle())
RunLoop.main.run()
