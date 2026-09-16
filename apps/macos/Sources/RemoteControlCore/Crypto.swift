// BLAKE2b and Argon2id live in their own target so they can be built with -O
// even in debug configurations (see Package.swift). Re-exported here so that
// `import RemoteControlCore` is all any caller — app or test — ever needs.
@_exported import RCCrypto
