package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/containerly/apppod/internal/builder"
	"github.com/containerly/apppod/internal/bundle"
	"github.com/containerly/apppod/internal/compose"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "pack":
		if err := runPack(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "build-image":
		// Legacy Phase 0 command — kept for backwards compatibility
		if err := runBuildImage(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", os.Args[1])
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Fprintln(os.Stderr, "Usage: apppod <command> [flags]")
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "Commands:")
	fmt.Fprintln(os.Stderr, "  pack           Build a distributable .app bundle from a docker-compose.yml")
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "Run 'apppod pack --help' for details.")
}

func runPack(args []string) error {
	fs := flag.NewFlagSet("pack", flag.ExitOnError)
	composePath := fs.String("compose", "./docker-compose.yml", "Path to docker-compose.yml")
	outputPath := fs.String("output", "", "Output path for .app bundle (default: ./<name> from x-apppod)")
	unsigned := fs.Bool("unsigned", false, "Skip signing, notarization, and .dmg creation")
	fs.Parse(args)

	// Step 1: Check Docker
	fmt.Println("[1] Checking Docker...")
	if err := builder.CheckDocker(); err != nil {
		return err
	}

	// Step 2: Parse and validate compose file
	fmt.Printf("[2] Parsing %s...\n", *composePath)
	cfg, err := compose.Parse(*composePath)
	if err != nil {
		return fmt.Errorf("compose validation failed: %w", err)
	}
	fmt.Printf("    App: %s v%s (%s)\n", cfg.Name, cfg.Version, cfg.Identifier)
	fmt.Printf("    Images: %d, Ports: %v\n", len(cfg.Images), cfg.HostPorts)
	if len(cfg.EnvFiles) > 0 {
		fmt.Printf("    Env files: %d\n", len(cfg.EnvFiles))
	}

	// Resolve output path
	output := *outputPath
	if output == "" {
		output = "./" + cfg.Name
	}

	// Create temp build directory for artifacts
	buildDir, err := os.MkdirTemp("", "apppod-artifacts-*")
	if err != nil {
		return fmt.Errorf("creating build directory: %w", err)
	}
	defer os.RemoveAll(buildDir)

	// Steps 3-N: Build root image (pull, save, build container, compress)
	if err := builder.Build(cfg, buildDir, 2); err != nil {
		return err
	}

	// Assemble .app bundle
	fmt.Println("[*] Assembling .app bundle...")
	if err := bundle.Assemble(cfg, buildDir, output); err != nil {
		return fmt.Errorf("assembling bundle: %w", err)
	}

	if *unsigned {
		fmt.Println("")
		fmt.Printf("Build complete (unsigned): %s.app\n", output)
		fmt.Println("Note: unsigned apps will show a Gatekeeper warning on end-user machines.")
	} else {
		// Phase 5 will add signing here
		fmt.Println("")
		fmt.Printf("Build complete: %s.app\n", output)
		fmt.Println("Note: signing and notarization will be available in a future release.")
		fmt.Println("      Use --unsigned to suppress this message.")
	}

	return nil
}

// runBuildImage is the legacy Phase 0 build-image command.
func runBuildImage(args []string) error {
	outputDir := defaultOutputDir()
	for i := 0; i < len(args); i++ {
		if args[i] == "--output" && i+1 < len(args) {
			outputDir = args[i+1]
			i++
		}
	}

	fmt.Println("[1/4] Checking Docker...")
	if err := builder.CheckDocker(); err != nil {
		return err
	}

	fmt.Println("Note: 'build-image' is deprecated. Use 'apppod pack' instead.")
	return nil
}

func defaultOutputDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "."
	}
	return home + "/Library/Application Support/AppPod"
}
