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
	builderImageName = "apppod-builder"
	builderDockerfile = "internal/builder/Dockerfile.builder"
	baseSizeMB       = 600 // Alpine + Docker Engine + packages
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
// 1. Pull all container images (linux/arm64)
// 2. Save images as .tar files
// 3. Calculate dynamic image size
// 4. Build and run the builder container
// 5. Copy artifacts (compressed root image, kernel, initramfs)
func Build(cfg *compose.Config, outputDir string, stepOffset int) error {
	workspace, err := os.MkdirTemp("", "apppod-build-*")
	if err != nil {
		return fmt.Errorf("creating workspace: %w", err)
	}
	defer os.RemoveAll(workspace)

	imgDir := filepath.Join(workspace, "images")
	if err := os.MkdirAll(imgDir, 0o755); err != nil {
		return fmt.Errorf("creating image dir: %w", err)
	}

	// Pull and save images
	step := stepOffset
	for i, image := range cfg.Images {
		step++
		fmt.Printf("[%d] Pulling image %d/%d: %s\n", step, i+1, len(cfg.Images), image)
		if err := pullImage(image); err != nil {
			return fmt.Errorf("pulling %s: %w", image, err)
		}

		tarName := sanitizeImageName(image) + ".tar"
		tarPath := filepath.Join(imgDir, tarName)
		fmt.Printf("[%d] Saving %s\n", step, tarName)
		if err := saveImage(image, tarPath); err != nil {
			return fmt.Errorf("saving %s: %w", image, err)
		}
	}

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

	// Calculate dynamic image size
	imageSizeMB, err := calculateImageSize(imgDir)
	if err != nil {
		return fmt.Errorf("calculating image size: %w", err)
	}

	// Build builder image
	step++
	fmt.Printf("[%d] Building builder container...\n", step)
	if err := buildBuilderImage(); err != nil {
		return fmt.Errorf("building builder image: %w", err)
	}

	// Run builder container with workspace mounted
	step++
	fmt.Printf("[%d] Building root image (%d MB)...\n", step, imageSizeMB)
	containerID, err := runBuilder(workspace, imageSizeMB)
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

func pullImage(image string) error {
	cmd := exec.Command("docker", "pull", "--platform", "linux/arm64", image)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func saveImage(image, tarPath string) error {
	cmd := exec.Command("docker", "save", "-o", tarPath, image)
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// sanitizeImageName converts an image reference to a safe filename.
func sanitizeImageName(image string) string {
	r := strings.NewReplacer("/", "_", ":", "_", ".", "_")
	return r.Replace(image)
}

// calculateImageSize computes: baseSizeMB + sum(tar sizes) + 25% headroom.
func calculateImageSize(imgDir string) (int, error) {
	var totalTarBytes int64
	entries, err := os.ReadDir(imgDir)
	if err != nil {
		return 0, err
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tar") {
			info, err := e.Info()
			if err != nil {
				return 0, err
			}
			totalTarBytes += info.Size()
		}
	}

	tarMB := int(totalTarBytes / (1024 * 1024))
	// Base + tar sizes + 25% headroom, minimum 2048 MB
	total := baseSizeMB + tarMB
	total = total + total/4 // +25%
	if total < 2048 {
		total = 2048
	}
	return total, nil
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

func runBuilder(workspace string, imageSizeMB int) (string, error) {
	cmd := exec.Command(
		"docker", "run",
		"--platform", "linux/arm64",
		"--privileged",
		"--detach",
		"-v", fmt.Sprintf("%s:/workspace:ro", workspace),
		"-e", fmt.Sprintf("IMG_SIZE_MB=%d", imageSizeMB),
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
