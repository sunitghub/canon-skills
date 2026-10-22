//go:build !linux

package common

// No /proc/net here (macOS, Windows): the same-user peer check allows every connection, as before t-68ae.
const peerSupported = false

var procNetDir = ""
