package common

import "os"

// Windows has no unix owner or mode bits; the per-user default (the user cache dir) is already private to the user.
func stateDirOwnerOK(string, os.FileInfo) error { return nil }
