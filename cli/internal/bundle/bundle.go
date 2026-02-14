package bundle

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/containerly/apppod/internal/compose"
)

// Assemble creates a .app bundle from build artifacts.
//
// Layout:
//
//	<name>.app/Contents/
//	├── MacOS/AppPod
//	├── Resources/
//	│   ├── docker-compose.yml
//	│   ├── *.env
//	│   ├── vmlinuz-lts
//	│   ├── initramfs-lts
//	│   └── vm-root.img.lz4
//	└── Info.plist
func Assemble(cfg *compose.Config, buildDir, outputPath string) error {
	appDir := outputPath
	if !strings.HasSuffix(appDir, ".app") {
		appDir += ".app"
	}

	contentsDir := filepath.Join(appDir, "Contents")
	macosDir := filepath.Join(contentsDir, "MacOS")
	resourcesDir := filepath.Join(contentsDir, "Resources")

	// Create directory structure
	for _, dir := range []string{macosDir, resourcesDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("creating %s: %w", dir, err)
		}
	}

	// Copy build artifacts to Resources
	artifacts := map[string]string{
		"vm-root.img.lz4": "vm-root.img.lz4",
		"vmlinuz-lts":     "vmlinuz-lts",
		"initramfs-lts":   "initramfs-lts",
	}
	for src, dst := range artifacts {
		srcPath := filepath.Join(buildDir, src)
		dstPath := filepath.Join(resourcesDir, dst)
		if err := copyFile(srcPath, dstPath); err != nil {
			return fmt.Errorf("copying %s: %w", src, err)
		}
	}

	// Copy compose file
	if err := copyFile(cfg.ComposePath, filepath.Join(resourcesDir, "docker-compose.yml")); err != nil {
		return fmt.Errorf("copying compose file: %w", err)
	}

	// Copy env files
	for _, envFile := range cfg.EnvFiles {
		dst := filepath.Join(resourcesDir, filepath.Base(envFile))
		if err := copyFile(envFile, dst); err != nil {
			return fmt.Errorf("copying env file %s: %w", filepath.Base(envFile), err)
		}
	}

	// Generate Info.plist
	plist := generateInfoPlist(cfg)
	plistPath := filepath.Join(contentsDir, "Info.plist")
	if err := os.WriteFile(plistPath, []byte(plist), 0o644); err != nil {
		return fmt.Errorf("writing Info.plist: %w", err)
	}

	// Copy AppPod binary (look for pre-built binary)
	binaryDst := filepath.Join(macosDir, "AppPod")
	binarySrc := findBinary()
	if binarySrc != "" {
		if err := copyFile(binarySrc, binaryDst); err != nil {
			return fmt.Errorf("copying AppPod binary: %w", err)
		}
		// Ensure executable
		_ = os.Chmod(binaryDst, 0o755)
	} else {
		fmt.Println("  Warning: AppPod binary not found — bundle needs manual binary placement at:")
		fmt.Printf("  %s\n", binaryDst)
	}

	fmt.Printf("  -> %s\n", appDir)
	return nil
}

// findBinary looks for a pre-built AppPod binary in common locations.
func findBinary() string {
	candidates := []string{
		"AppPod",
		"AppPod.app/Contents/MacOS/AppPod",
		".build/release/AppPod",
		".build/debug/AppPod",
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return ""
}

func generateInfoPlist(cfg *compose.Config) string {
	displayName := cfg.DisplayName
	if displayName == "" {
		displayName = titleCase(cfg.Name)
	}

	// Convert identifier to reverse-DNS bundle ID
	bundleID := cfg.Identifier
	if !strings.Contains(bundleID, ".") {
		// If it looks like a GitHub URL, convert to reverse-DNS
		bundleID = strings.ReplaceAll(bundleID, "/", ".")
	}

	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>%s</string>
	<key>CFBundleName</key>
	<string>%s</string>
	<key>CFBundleDisplayName</key>
	<string>%s</string>
	<key>CFBundleExecutable</key>
	<string>AppPod</string>
	<key>CFBundleVersion</key>
	<string>%s</string>
	<key>CFBundleShortVersionString</key>
	<string>%s</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHumanReadableCopyright</key>
	<string>Built with AppPod</string>
</dict>
</plist>
`, bundleID, cfg.Name, displayName, cfg.Version, cfg.Version)
}

func titleCase(name string) string {
	words := strings.FieldsFunc(name, func(r rune) bool {
		return r == '-' || r == '_'
	})
	for i, w := range words {
		if len(w) > 0 {
			words[i] = strings.ToUpper(w[:1]) + strings.ToLower(w[1:])
		}
	}
	return strings.Join(words, " ")
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}
