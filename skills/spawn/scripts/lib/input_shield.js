ObjC.import('Cocoa');

var WORK_MAX_SECONDS = 7;
var RESTORE_MIN_SECONDS = 1;
var DONE_SECONDS = 1.5;
var RESTORE_MAX_SECONDS = 5;
var MIN_WIDTH = 360, MAX_WIDTH = 600, PAD = 40, RADIUS = 18;
// Bottom-up layout (Cocoa origin): the status row, the session name, then the heading.
var STATUS_Y = 32, NAME_Y = 70, HEADING_Y = 100, HEIGHT = 146;
var ICON = 16, ICON_GAP = 7;
// AppKit enum values; JXA does not expose all of these as $ constants.
var STYLE_TITLED = 1, STYLE_NONACTIVATING = 1 << 7, STYLE_FULL_SIZE_CONTENT = 1 << 15;
var TITLE_HIDDEN = 1;
var MATERIAL_HUD = 13, BLENDING_BEHIND_WINDOW = 0, EFFECT_STATE_ACTIVE = 1;
var SPINNER_STYLE = 1, CONTROL_SIZE_SMALL = 1;
var ANIMATION_ALERT_PANEL = 5;
var BUTTONS = [0, 1, 2]; // close, miniaturize, zoom

function run(argv) {
  var name = argv[0] || 'new session';
  var terminal = argv[1] || 'terminal';
  var stateDir = argv[2];
  var bounds = argv.length >= 7 ? argv.slice(3, 7).map(parseFloat) : null;
  var fm = $.NSFileManager.defaultManager;
  function exists(f) { return fm.fileExistsAtPath(stateDir + '/' + f); }
  function touch(f) { fm.createFileAtPathContentsAttributes(stateDir + '/' + f, $(), $()); }

  var app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);

  function makeLabel(text, font, color) {
    var l = $.NSTextField.labelWithString(text);
    l.font = font;
    l.textColor = color;
    l.lineBreakMode = $.NSLineBreakByTruncatingMiddle;
    return l;
  }
  var heading = makeLabel('Starting agent session:', $.NSFont.systemFontOfSizeWeight(12, $.NSFontWeightMedium),
    $.NSColor.secondaryLabelColor);
  var title = makeLabel(name, $.NSFont.systemFontOfSizeWeight(20, $.NSFontWeightSemibold), $.NSColor.labelColor);
  var status = makeLabel('Opening new ' + terminal + ' tab...', $.NSFont.systemFontOfSize(12),
    $.NSColor.secondaryLabelColor);

  function fittedWidth(l) { l.sizeToFit; return l.frame.size.width; }
  var width = Math.round(Math.max(MIN_WIDTH, Math.min(MAX_WIDTH, fittedWidth(title) + 2 * PAD)));
  // by frame: NSTextAlignment values differ between Intel and Apple Silicon
  function place(l, y) {
    var w = Math.min(fittedWidth(l), width - 2 * PAD);
    l.frame = $.NSMakeRect(Math.round((width - w) / 2), y, w, l.frame.size.height);
  }

  // a titled window (title bar hidden) is what lets a nonactivating panel become key without a subclass
  var panel = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, width, HEIGHT), STYLE_TITLED | STYLE_NONACTIVATING | STYLE_FULL_SIZE_CONTENT,
    $.NSBackingStoreBuffered, false);
  panel.titlebarAppearsTransparent = true;
  panel.titleVisibility = TITLE_HIDDEN;
  // dark, so label colors resolve for the dark translucent material whatever the system appearance
  panel.appearance = $.NSAppearance.appearanceNamed($.NSAppearanceNameDarkAqua);
  BUTTONS.forEach(function (b) {
    var btn = panel.standardWindowButton(b);
    if (btn && !btn.isNil()) btn.hidden = true;
  });
  panel.movable = false;
  panel.opaque = false;
  panel.backgroundColor = $.NSColor.clearColor;
  panel.level = $.NSStatusWindowLevel;
  panel.collectionBehavior =
    $.NSWindowCollectionBehaviorCanJoinAllSpaces | $.NSWindowCollectionBehaviorFullScreenAuxiliary;
  panel.hidesOnDeactivate = false;

  var effect = $.NSVisualEffectView.alloc.initWithFrame($.NSMakeRect(0, 0, width, HEIGHT));
  effect.material = MATERIAL_HUD;
  effect.blendingMode = BLENDING_BEHIND_WINDOW;
  effect.state = EFFECT_STATE_ACTIVE;
  effect.wantsLayer = true;
  effect.layer.cornerRadius = RADIUS;
  effect.layer.masksToBounds = true;
  panel.contentView = effect;

  var spinner = $.NSProgressIndicator.alloc.initWithFrame($.NSMakeRect(0, 0, ICON, ICON));
  spinner.style = SPINNER_STYLE;
  spinner.controlSize = CONTROL_SIZE_SMALL;
  spinner.indeterminate = true;
  spinner.startAnimation(null);
  var check = null;
  [heading, title, status, spinner].forEach(function (v) { effect.addSubview(v); });
  place(heading, HEADING_Y);
  place(title, NAME_Y);

  function setStatus(text) {
    status.stringValue = text;
    var textWidth = Math.min(fittedWidth(status), width - 2 * PAD - ICON - ICON_GAP);
    var x = Math.round((width - (ICON + ICON_GAP + textWidth)) / 2);
    var iconY = STATUS_Y + Math.round((status.frame.size.height - ICON) / 2);
    spinner.frame = $.NSMakeRect(x, iconY, ICON, ICON);
    if (check) check.frame = $.NSMakeRect(x, iconY, ICON, ICON);
    status.frame = $.NSMakeRect(x + ICON + ICON_GAP, STATUS_Y, textWidth, status.frame.size.height);
  }
  setStatus(status.stringValue.js);

  if (bounds) {
    // AppleScript bounds are top-left based on the primary screen; Cocoa frames are bottom-left based
    var primaryHeight = $.NSScreen.screens.objectAtIndex(0).frame.size.height;
    var cx = (bounds[0] + bounds[2]) / 2;
    var cy = primaryHeight - (bounds[1] + bounds[3]) / 2;
    panel.setFrameOrigin($.NSMakePoint(Math.round(cx - width / 2), Math.round(cy - HEIGHT / 2)));
  } else {
    panel.center;
  }
  panel.animationBehavior = ANIMATION_ALERT_PANEL;
  panel.makeKeyAndOrderFront(null);

  function showDone() {
    spinner.stopAnimation(null);
    spinner.hidden = true;
    var img = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription('checkmark.circle.fill', 'Done');
    if (img && !img.isNil()) {
      img = img.imageWithSymbolConfiguration(
        $.NSImageSymbolConfiguration.configurationWithPointSizeWeight(ICON, $.NSFontWeightRegular));
      check = $.NSImageView.imageViewWithImage(img);
      check.contentTintColor = $.NSColor.secondaryLabelColor;
      effect.addSubview(check);
    }
    setStatus('Done!');
  }

  function since(date) { return -date.timeIntervalSinceNow; }
  var shownAt = $.NSDate.date;
  var shown = false, refocused = false, ready = false, launching = false, restoringAt = null, doneAt = null;
  while (true) {
    var ev = app.nextEventMatchingMaskUntilDateInModeDequeue(
      $.NSEventMaskAny, $.NSDate.dateWithTimeIntervalSinceNow(0.03), $.NSDefaultRunLoopMode, true);
    if (!shown && panel.isVisible) { touch('shown'); shown = true; }
    if (!refocused && exists('focus')) { panel.makeKeyAndOrderFront(null); refocused = true; }
    if (refocused && !ready && panel.isKeyWindow) { touch('ready'); ready = true; }
    if (!launching && !restoringAt && exists('launching')) { launching = true; setStatus('Launching Claude Code...'); }
    if (!restoringAt && exists('restoring')) { restoringAt = $.NSDate.date; setStatus('Restoring focus...'); }
    if (!restoringAt && since(shownAt) >= WORK_MAX_SECONDS) break;
    if (restoringAt && !doneAt && exists('close') && since(restoringAt) >= RESTORE_MIN_SECONDS) {
      doneAt = $.NSDate.date;
      showDone();
    }
    if (restoringAt && (since(restoringAt) >= RESTORE_MAX_SECONDS || (doneAt && since(doneAt) >= DONE_SECONDS))) break;
    if (!ev || ev.isNil()) continue;
    var type = ev.type;
    if (type == $.NSEventTypeKeyDown || type == $.NSEventTypeKeyUp) continue;
    app.sendEvent(ev);
  }
  panel.close;
}
