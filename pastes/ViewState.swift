import SwiftUI

// SDK 27 also defines a @State macro whose plugin ships only with Xcode.
// An alias selects the existing property wrapper on every supported SDK.
typealias ViewState<Value> = SwiftUI.State<Value>
