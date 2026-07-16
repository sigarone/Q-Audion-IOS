//
//  SampleHandler.swift
//  QAudionBroadcastExtension
//
//  ReplayKit Broadcast Upload Extension entry point for group-call screen
//  sharing. All the real work (Unix-domain-socket IPC to the main app,
//  sample-buffer relay, Darwin notification handshake) lives in LiveKit's
//  own `LKSampleHandler` (client-sdk-swift, Sources/LiveKit/Broadcast/):
//  this subclass only needs to opt into logging. See
//  QAudionApp/project.yml's QAudionBroadcastExtension target for why this
//  links the bare `LiveKit` product directly instead of QAudionEngine.
//

import LiveKit

class SampleHandler: LKSampleHandler {
    override var enableLogging: Bool { true }
}
