package builder

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

const (
	builderImageName = "apppod-builder"
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

// BuildRootImage orchestrates the full root image build:
// 1. Check Docker is running
// 2. Build the builder container (linux/arm64)
// 3. Run it to produce the ext4 image, kernel, and initramfs
// 4. Copy artifacts to outputDir
func BuildRootImage(outputDir string) error {
	fmt.Println("[1/4] Checking Docker...")
	if err := CheckDocker(); err != nil {
		return err
	}

	fmt.Println("[2/4] Building builder container...")
	if err := buildBuilderImage(); err != nil {
		return fmt.Errorf("building builder image: %w", err)
	}

	fmt.Println("[3/4] Running builder container...")
	containerID, err := runBuilder()
	if err != nil {
		return fmt.Errorf("running builder: %w", err)
	}
	defer cleanupContainer(containerID)

	fmt.Println("[4/4] Copying artifacts...")
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return fmt.Errorf("creating output directory: %w", err)
	}

	artifacts := []string{"vm-root.img", "vmlinuz-lts", "initramfs-lts"}
	for _, name := range artifacts {
		src := fmt.Sprintf("%s:/output/%s", containerID, name)
		dst := filepath.Join(outputDir, name)
		if err := dockerCp(src, dst); err != nil {
			return fmt.Errorf("copying %s: %w", name, err)
		}
		fmt.Printf("  → %s\n", dst)
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

func runBuilder() (string, error) {
	cmd := exec.Command(
		"docker", "run",
		"--platform", "linux/arm64",
		"--privileged",
		"--detach",
		builderImageName,
	)
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	// Container ID is the output, trimmed
	containerID := string(out[:len(out)-1])

	// Wait for it to finish
	waitCmd := exec.Command("docker", "wait", containerID)
	waitOut, err := waitCmd.Output()
	if err != nil {
		return containerID, fmt.Errorf("waiting for builder: %w", err)
	}

	exitCode := string(waitOut[:len(waitOut)-1])
	if exitCode != "0" {
		// Print logs for debugging
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
