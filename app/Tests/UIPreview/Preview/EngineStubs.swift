import Foundation
/// The engine calls the on-screen controls make, which do nothing here: the controls sandbox sends what is pressed to its own readout (ControlOutput).
func winios_pointer(_ x: Int32, _ y: Int32, _ flags: UInt32, _ data: UInt32) {}
func winios_post_key(_ vk: Int32, _ down: Int32) {}
import UIKit
/// In the app this lives with the in-game HUD, which decides which views take its touches.
protocol TakesHUDTouches: UIView {}
