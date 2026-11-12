// Stand-in for the app's ControllerInput (UI/Kit/Focus.swift needs UIKit-era types): FocusScope only asks whether a controller is connected.
final class ControllerInput { @MainActor static let shared = ControllerInput(); var connected = false }
