import Foundation

let screen = CGRect(x: 0, y: 0, width: 1001, height: 801)
func hand(pinch: Bool = false, palm: Bool = false) -> [CGPoint] {
    var p = Array(repeating: CGPoint(x: 0.5, y: 0.6), count: 21)
    p[0] = CGPoint(x: 0.5, y: 0.9)
    p[3] = CGPoint(x: 0.35, y: 0.65)
    p[4] = CGPoint(x: 0.15, y: 0.5)
    for (tip, joint, x) in [(8, 6, 0.35), (12, 10, 0.5), (16, 14, 0.65), (20, 18, 0.8)] {
        p[joint] = CGPoint(x: x, y: 0.55)
        p[tip] = CGPoint(x: x, y: palm || tip == 8 ? 0.2 : 0.65)
    }
    p[17] = CGPoint(x: 0.75, y: 0.65)
    if pinch { p[4] = p[8] }
    return p
}
func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}
var engine = GestureEngine()
let first = engine.process(hand(), time: 0, screen: screen)
check(first.point == CGPoint(x: 650, y: 160), "Mirrored mapping and top-left coordinates")
check(engine.process(hand(pinch: true), time: 0.1, screen: screen).click, "First pinch clicks")
for i in 2...10 {
    check(!engine.process(hand(pinch: true), time: Double(i) / 10, screen: screen).click, "Held pinch must not repeat")
}
_ = engine.process(hand(), time: 1.1, screen: screen)
check(engine.process(hand(pinch: true), time: 1.2, screen: screen).click, "Release rearms click")
_ = engine.process([], time: 1.3, screen: screen)
check(!engine.process(hand(pinch: true), time: 1.4, screen: screen).click, "Reappearing pinched must not click")
engine.setEnabled(true)
for i in 0...9 { _ = engine.process(hand(palm: true), time: Double(i) / 10, screen: screen) }
check(engine.mode == .active, "Palm must be held for one second")
_ = engine.process(hand(palm: true), time: 1, screen: screen)
check(engine.mode == .paused, "Palm pauses")
check(engine.process(hand(), time: 1.1, screen: screen).point == nil, "Hand still in frame cannot resume")
_ = engine.process([], time: 1.2, screen: screen)
_ = engine.process([], time: 1.8, screen: screen)
check(engine.process(hand(), time: 1.9, screen: screen).point != nil, "Hand reappearance resumes")
engine.setEnabled(false)
_ = engine.process([], time: 2, screen: screen)
_ = engine.process([], time: 3, screen: screen)
check(engine.process(hand(), time: 3.1, screen: screen).point == nil, "Manual Off must stay off")
engine.setEnabled(true)
_ = engine.process(hand(), time: 4, screen: screen)
var moved = hand()
moved[8].x = 0.75
let smooth = engine.process(moved, time: 4.1, screen: screen)
check(abs(smooth.point!.x - 550) < 0.001, "Lerp smooths cursor")
print("PASS: mirrored mapping, smoothing, pinch hysteresis, hand loss, palm pause, reappearance, manual Off")
