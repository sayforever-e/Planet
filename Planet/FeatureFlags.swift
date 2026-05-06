//
//  FeatureFlags.swift
//  Planet
//

enum FeatureFlags {
    #if PLANET_ENABLE_APPLE_INTELLIGENCE
    static let appleIntelligenceSupport = true
    #else
    static let appleIntelligenceSupport = false
    #endif
}
