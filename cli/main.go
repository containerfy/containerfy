package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/containerly/apppod/internal/builder"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "Usage: apppod <command> [flags]")
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "Commands:")
		fmt.Fprintln(os.Stderr, "  build-image    Build the root VM image (Phase 0)")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "build-image":
		outputDir := defaultOutputDir()
		for i := 2; i < len(os.Args); i++ {
			if os.Args[i] == "--output" && i+1 < len(os.Args) {
				outputDir = os.Args[i+1]
				i++
			}
		}

		if err := builder.BuildRootImage(outputDir); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("Build complete.")

	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}

func defaultOutputDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "."
	}
	return filepath.Join(home, "Library", "Application Support", "AppPod")
}
