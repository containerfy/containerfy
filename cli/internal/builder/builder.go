package builder

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/containerly/apppod/internal/compose"
)

const (
	builderImageName  = "apppod-builder"
	builderDockerfile = "internal/builder/Dockerfile.builder"
)

// CheckDocker verifies that Docker is running and accessible.
func CheckDocker() error {
	cmd := exec.Command("docker", "info")
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("docker is not running or not accessible: %w", err)
	}
	return nil
}

// Build orchestrates the full root image build for apppod pack:
// 1. Build the builder container image
// 2. Run it with workspace + image list (pulls images via Docker-in-Docker)
// 3. Copy artifacts (compressed root image, kernel, initramfs)
func Build(cfg *compose.Config, outputDir string, stepOffset int) error {
	workspace, err := os.MkdirTemp("", "apppod-build-*")
	if err != nil {
		return fmt.Errorf("creating workspace: %w", err)
	}
	defer os.RemoveAll(workspace)

	// Copy compose file to workspace
	composeData, err := os.ReadFile(cfg.ComposePath)
	if err != nil {
		return fmt.Errorf("reading compose file: %w", err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "docker-compose.yml"), composeData, 0o644); err != nil {
		return fmt.Errorf("copying compose file: %w", err)
	}

	// Copy env files to workspace
	for _, envFile := range cfg.EnvFiles {
		dst := filepath.Join(workspace, filepath.Base(envFile))
		data, err := os.ReadFile(envFile)
		if err != nil {
			return fmt.Errorf("reading env file %s: %w", envFile, err)
		}
		if err := os.WriteFile(dst, data, 0o644); err != nil {
			return fmt.Errorf("copying env file: %w", err)
		}
	}

	// Build builder image
	step := stepOffset + 1
	fmt.Printf("[%d] Building builder container...\n", step)
	if err := buildBuilderImage(); err != nil {
		return fmt.Errorf("building builder image: %w", err)
	}

	// Run builder container — pulls images directly via Docker-in-Docker
	step++
	fmt.Printf("[%d] Building root image (pulling %d images)...\n", step, len(cfg.Images))
	containerID, err := runBuilder(workspace, cfg.Images)
	if err != nil {
		return fmt.Errorf("running builder: %w", err)
	}
	defer cleanupContainer(containerID)

	// Copy artifacts
	step++
	fmt.Printf("[%d] Copying artifacts...\n", step)
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return fmt.Errorf("creating output directory: %w", err)
	}

	artifacts := []string{"vm-root.img.lz4", "vmlinuz-lts", "initramfs-lts"}
	for _, name := range artifacts {
		src := fmt.Sprintf("%s:/output/%s", containerID, name)
		dst := filepath.Join(outputDir, name)
		if err := dockerCp(src, dst); err != nil {
			return fmt.Errorf("copying %s: %w", name, err)
		}
		fmt.Printf("  -> %s\n", dst)
	}

	return nil
}

func buildBuilderImage() error {
	cmd := exec.Command(
		"docker", "build",
		"--platform", "linux/arm64",
		"-t", builderImageName,
		"-f", builderDockerfile,
		".",
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func runBuilder(workspace string, images []string) (string, error) {
	cmd := exec.Command(
		"docker", "run",
		"--platform", "linux/arm64",
		"--privileged",
		"--detach",
		"-v", fmt.Sprintf("%s:/workspace:ro", workspace),
		"-e", fmt.Sprintf("APPPOD_IMAGES=%s", strings.Join(images, " ")),
		builderImageName,
	)
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	containerID := strings.TrimSpace(string(out))

	// Wait for completion
	waitCmd := exec.Command("docker", "wait", containerID)
	waitOut, err := waitCmd.Output()
	if err != nil {
		return containerID, fmt.Errorf("waiting for builder: %w", err)
	}

	exitCode := strings.TrimSpace(string(waitOut))
	if exitCode != "0" {
		logsCmd := exec.Command("docker", "logs", containerID)
		logsCmd.Stdout = os.Stderr
		logsCmd.Stderr = os.Stderr
		_ = logsCmd.Run()
		return containerID, fmt.Errorf("builder exited with code %s", exitCode)
	}

	return containerID, nil
}

func dockerCp(src, dst string) error {
	cmd := exec.Command("docker", "cp", src, dst)
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func cleanupContainer(containerID string) {
	cmd := exec.Command("docker", "rm", "-f", containerID)
	cmd.Stdout = nil
	cmd.Stderr = nil
	_ = cmd.Run()
}
