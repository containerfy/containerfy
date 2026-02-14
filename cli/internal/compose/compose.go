package compose

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config holds the validated result of parsing a compose file.
type Config struct {
	Name        string
	Version     string
	Identifier  string
	DisplayName string
	Icon        string

	CPUMin             int
	CPURecommended     int
	MemoryMBMin        int
	MemoryMBRecommended int
	DiskMB             int

	HealthcheckURL string

	Images    []string // unique image references to pull
	HostPorts []int    // host ports from port mappings
	EnvFiles  []string // absolute paths to env files to bundle

	ComposePath string // absolute path to compose file
	ComposeDir  string // directory containing compose file
}

var nameRegex = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9-]{0,63}$`)
var semverRegex = regexp.MustCompile(`^\d+\.\d+\.\d+`)

// Parse reads and validates a docker-compose.yml file for apppod pack.
func Parse(composePath string) (*Config, error) {
	absPath, err := filepath.Abs(composePath)
	if err != nil {
		return nil, fmt.Errorf("resolving path: %w", err)
	}

	data, err := os.ReadFile(absPath)
	if err != nil {
		return nil, fmt.Errorf("reading compose file: %w", err)
	}

	var raw map[string]interface{}
	if err := yaml.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("parsing YAML: %w", err)
	}

	cfg := &Config{
		ComposePath: absPath,
		ComposeDir:  filepath.Dir(absPath),
	}

	// Parse and validate x-apppod block
	xApppod, ok := raw["x-apppod"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("missing or invalid x-apppod block")
	}
	if err := parseXApppod(xApppod, cfg); err != nil {
		return nil, err
	}

	// Parse services: extract images/ports, detect env_files, reject bad keywords
	services, ok := raw["services"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("missing or invalid services block")
	}
	if err := parseServices(services, cfg); err != nil {
		return nil, err
	}

	// Must have at least one exposed port
	if len(cfg.HostPorts) == 0 {
		return nil, fmt.Errorf("no services with ports: found — at least one exposed port is required")
	}

	// Cross-validate healthcheck URL port against service ports
	if err := validateHealthcheckPort(cfg); err != nil {
		return nil, err
	}

	return cfg, nil
}

// parseXApppod validates and extracts all x-apppod fields.
func parseXApppod(x map[string]interface{}, cfg *Config) error {
	// name (required)
	name, _ := x["name"].(string)
	if name == "" {
		return fmt.Errorf("x-apppod.name is required")
	}
	if !nameRegex.MatchString(name) {
		return fmt.Errorf("x-apppod.name %q is invalid: must match %s", name, nameRegex.String())
	}
	cfg.Name = name

	// version (required)
	version, _ := x["version"].(string)
	if version == "" {
		return fmt.Errorf("x-apppod.version is required")
	}
	if !semverRegex.MatchString(version) {
		return fmt.Errorf("x-apppod.version %q is not valid semver", version)
	}
	cfg.Version = version

	// identifier (required)
	identifier, _ := x["identifier"].(string)
	if identifier == "" {
		return fmt.Errorf("x-apppod.identifier is required")
	}
	cfg.Identifier = identifier

	// display_name (optional)
	cfg.DisplayName, _ = x["display_name"].(string)

	// icon (optional)
	cfg.Icon, _ = x["icon"].(string)

	// vm (required)
	vm, ok := x["vm"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("x-apppod.vm is required")
	}
	if err := parseVM(vm, cfg); err != nil {
		return err
	}

	// healthcheck (required)
	hc, ok := x["healthcheck"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("x-apppod.healthcheck is required")
	}
	hcURL, _ := hc["url"].(string)
	if hcURL == "" {
		return fmt.Errorf("x-apppod.healthcheck.url is required")
	}
	parsed, err := url.Parse(hcURL)
	if err != nil || parsed.Hostname() != "127.0.0.1" {
		return fmt.Errorf("x-apppod.healthcheck.url must target 127.0.0.1, got %q", hcURL)
	}
	cfg.HealthcheckURL = hcURL

	return nil
}

func parseVM(vm map[string]interface{}, cfg *Config) error {
	// cpu
	cpu, ok := vm["cpu"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("x-apppod.vm.cpu is required")
	}
	cpuMin := toInt(cpu["min"])
	if cpuMin < 1 || cpuMin > 16 {
		return fmt.Errorf("x-apppod.vm.cpu.min must be 1-16, got %d", cpuMin)
	}
	cfg.CPUMin = cpuMin
	cpuRec := toInt(cpu["recommended"])
	if cpuRec == 0 {
		cpuRec = cpuMin
	}
	if cpuRec < cpuMin {
		return fmt.Errorf("x-apppod.vm.cpu.recommended (%d) must be >= min (%d)", cpuRec, cpuMin)
	}
	cfg.CPURecommended = cpuRec

	// memory_mb
	mem, ok := vm["memory_mb"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("x-apppod.vm.memory_mb is required")
	}
	memMin := toInt(mem["min"])
	if memMin < 512 || memMin > 32768 {
		return fmt.Errorf("x-apppod.vm.memory_mb.min must be 512-32768, got %d", memMin)
	}
	cfg.MemoryMBMin = memMin
	memRec := toInt(mem["recommended"])
	if memRec == 0 {
		memRec = memMin
	}
	if memRec < memMin {
		return fmt.Errorf("x-apppod.vm.memory_mb.recommended (%d) must be >= min (%d)", memRec, memMin)
	}
	cfg.MemoryMBRecommended = memRec

	// disk_mb
	diskMB := toInt(vm["disk_mb"])
	if diskMB < 1024 {
		return fmt.Errorf("x-apppod.vm.disk_mb must be >= 1024, got %d", diskMB)
	}
	cfg.DiskMB = diskMB

	return nil
}

// parseServices extracts images, ports, env_files and rejects hard-rejected keywords.
func parseServices(services map[string]interface{}, cfg *Config) error {
	seen := make(map[string]bool)

	for name, svcRaw := range services {
		svc, ok := svcRaw.(map[string]interface{})
		if !ok {
			continue
		}

		// Reject hard-rejected keywords
		if _, has := svc["build"]; has {
			return fmt.Errorf("service %q uses build: which is not supported — use pre-built images only", name)
		}
		if _, has := svc["extends"]; has {
			return fmt.Errorf("service %q uses extends: which is not supported", name)
		}
		if profiles, has := svc["profiles"]; has && profiles != nil {
			return fmt.Errorf("service %q uses profiles: which is not supported in v1", name)
		}
		if nm, _ := svc["network_mode"].(string); nm == "host" {
			return fmt.Errorf("service %q uses network_mode: host which breaks vsock port forwarding", name)
		}

		// Check volumes for bind mounts
		if vols, ok := svc["volumes"].([]interface{}); ok {
			for _, v := range vols {
				if volStr, ok := v.(string); ok {
					if isBindMount(volStr) {
						return fmt.Errorf("service %q uses bind mount volume %q — only named volumes are supported", name, volStr)
					}
				}
				if volMap, ok := v.(map[string]interface{}); ok {
					if t, _ := volMap["type"].(string); t == "bind" {
						return fmt.Errorf("service %q uses bind mount volume — only named volumes are supported", name)
					}
				}
			}
		}

		// Extract image
		if image, ok := svc["image"].(string); ok && image != "" {
			if !seen[image] {
				seen[image] = true
				cfg.Images = append(cfg.Images, image)
			}
		}

		// Extract ports
		if ports, ok := svc["ports"].([]interface{}); ok {
			for _, p := range ports {
				if hp := parseHostPort(p); hp > 0 {
					cfg.HostPorts = append(cfg.HostPorts, hp)
				}
			}
		}

		// Extract env_file references
		if err := extractEnvFiles(svc, name, cfg); err != nil {
			return err
		}
	}

	return nil
}

func extractEnvFiles(svc map[string]interface{}, svcName string, cfg *Config) error {
	ef, exists := svc["env_file"]
	if !exists {
		return nil
	}

	var paths []string
	switch v := ef.(type) {
	case string:
		paths = []string{v}
	case []interface{}:
		for _, item := range v {
			if s, ok := item.(string); ok {
				paths = append(paths, s)
			} else if m, ok := item.(map[string]interface{}); ok {
				if p, ok := m["path"].(string); ok {
					paths = append(paths, p)
				}
			}
		}
	}

	for _, p := range paths {
		abs := p
		if !filepath.IsAbs(p) {
			abs = filepath.Join(cfg.ComposeDir, p)
		}
		if _, err := os.Stat(abs); err != nil {
			return fmt.Errorf("service %q references env_file %q which does not exist", svcName, p)
		}
		cfg.EnvFiles = append(cfg.EnvFiles, abs)
	}

	return nil
}

func validateHealthcheckPort(cfg *Config) error {
	parsed, err := url.Parse(cfg.HealthcheckURL)
	if err != nil {
		return err
	}
	portStr := parsed.Port()
	if portStr == "" {
		portStr = "80"
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		return fmt.Errorf("healthcheck URL has invalid port: %s", portStr)
	}

	for _, hp := range cfg.HostPorts {
		if hp == port {
			return nil
		}
	}

	return fmt.Errorf("healthcheck URL port %d does not match any service host port %v", port, cfg.HostPorts)
}

// isBindMount checks if a volume string is a bind mount (starts with ., /, or ~).
func isBindMount(vol string) bool {
	parts := strings.SplitN(vol, ":", 2)
	if len(parts) < 2 {
		return false
	}
	src := parts[0]
	return strings.HasPrefix(src, ".") || strings.HasPrefix(src, "/") || strings.HasPrefix(src, "~")
}

// parseHostPort extracts the host port from a port entry.
func parseHostPort(entry interface{}) int {
	switch v := entry.(type) {
	case int:
		return v
	case string:
		// Strip protocol suffix
		base := strings.SplitN(v, "/", 2)[0]
		parts := strings.Split(base, ":")
		switch len(parts) {
		case 1:
			p, _ := strconv.Atoi(parts[0])
			return p
		case 2:
			p, _ := strconv.Atoi(parts[0])
			return p
		case 3:
			// IP:host:container
			p, _ := strconv.Atoi(parts[1])
			return p
		}
	case map[string]interface{}:
		return toInt(v["published"])
	}
	return 0
}

func toInt(v interface{}) int {
	switch n := v.(type) {
	case int:
		return n
	case float64:
		return int(n)
	case string:
		i, _ := strconv.Atoi(n)
		return i
	}
	return 0
}
