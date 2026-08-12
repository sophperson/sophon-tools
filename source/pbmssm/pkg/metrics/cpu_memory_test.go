package metrics

import "testing"

// ---------------------------------------------------------------
// Memory — /proc/meminfo MemTotal/MemFree/MemAvailable (kB → MB, 对齐 bmssm)
// 真值：MemTotal 6427708 kB = 6277 MB
// ---------------------------------------------------------------

func TestMemory(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{
		"/proc/meminfo": "MemTotal:       6427708 kB\n" +
			"MemFree:        3672508 kB\n" +
			"MemAvailable:   5920400 kB\n" +
			"Buffers:         216168 kB\n" +
			"Cached:         1965660 kB\n",
	}}
	c := NewCollector(fr, nil)
	m := c.Memory()
	if m.Total != 6277 {
		t.Errorf("Memory.Total = %v, want 6277 (MB)", m.Total)
	}
	if m.Free != 3586 {
		t.Errorf("Memory.Free = %v, want 3586 (MB)", m.Free)
	}
	if m.Available != 5781 {
		t.Errorf("Memory.Available = %v, want 5781 (MB)", m.Available)
	}
}

func TestMemoryMissing(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{}}
	c := NewCollector(fr, nil)
	m := c.Memory()
	if m.Total != 0 || m.Free != 0 || m.Available != 0 {
		t.Errorf("Memory = %+v, want all zero when missing", m)
	}
}

func TestMemoryPartialMissing(t *testing.T) {
	// MemAvailable 缺失时应返 0，不阻断
	fr := &fakeFileReader{files: map[string]string{
		"/proc/meminfo": "MemTotal:       2048 kB\nMemFree:        1024 kB\n",
	}}
	c := NewCollector(fr, nil)
	m := c.Memory()
	if m.Total != 2 {
		t.Errorf("Memory.Total = %v, want 2", m.Total)
	}
	if m.Free != 1 {
		t.Errorf("Memory.Free = %v, want 1", m.Free)
	}
	if m.Available != 0 {
		t.Errorf("Memory.Available = %v, want 0 when absent", m.Available)
	}
}

// TestMemoryUsagePercentAvailable 使用率基于 MemAvailable（buff/cache 不计入）：
// Total 6277 MB、Available 5781 MB → (6277-5781)/6277 = 7.90%。
func TestMemoryUsagePercentAvailable(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{
		"/proc/meminfo": "MemTotal:       6427708 kB\n" +
			"MemFree:        3672508 kB\n" +
			"MemAvailable:   5920400 kB\n",
	}}
	c := NewCollector(fr, nil)
	got := c.MemoryUsagePercent()
	want := (6277.0 - 5781.0) / 6277.0 * 100.0 // ≈ 7.90
	if got < want-0.1 || got > want+0.1 {
		t.Errorf("MemoryUsagePercent = %v, want ~%v (available 口径)", got, want)
	}
}

// TestMemoryUsagePercentFallbackFree MemAvailable 缺失时退化为 MemFree：
// Total 2048 kB、Free 1024 kB → (2-1)/2 = 50%。
func TestMemoryUsagePercentFallbackFree(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{
		"/proc/meminfo": "MemTotal:       2048 kB\nMemFree:        1024 kB\n",
	}}
	c := NewCollector(fr, nil)
	got := c.MemoryUsagePercent()
	want := 50.0
	if got < want-0.01 || got > want+0.01 {
		t.Errorf("MemoryUsagePercent = %v, want %v (free 回退)", got, want)
	}
}

// TestMemoryUsagePercentMissing 无 meminfo 时返 0，不 panic。
func TestMemoryUsagePercentMissing(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{}}
	c := NewCollector(fr, nil)
	if got := c.MemoryUsagePercent(); got != 0 {
		t.Errorf("MemoryUsagePercent = %v, want 0 when missing", got)
	}
}

// ---------------------------------------------------------------
// CPUInfo — cores/freq/type 来自 /proc/cpuinfo + scaling_cur_freq
// 真值：8 核，2300000 kHz → 2300 MHz，model name bm1684x
// ---------------------------------------------------------------

func TestCPUInfo(t *testing.T) {
	cpuinfo := "processor\t: 0\nmodel name\t: bm1684x\nBogoMIPS\t: 100.00\n\n" +
		"processor\t: 1\nmodel name\t: bm1684x\nBogoMIPS\t: 100.00\n\n" +
		"processor\t: 2\nmodel name\t: bm1684x\nBogoMIPS\t: 100.00\n\n" +
		"processor\t: 3\nmodel name\t: bm1684x\nBogoMIPS\t: 100.00\n\n" +
		"processor\t: 4\nmodel name\t: bm1684x\nBogoMIPS\t: 100.00\n\n" +
		"processor\t: 5\nmodel name\t: bm1684x\nBogoMIPS\t: 100.00\n\n" +
		"processor\t: 6\nmodel name\t: bm1684x\nBogoMIPS\t: 100.00\n\n" +
		"processor\t: 7\nmodel name\t: bm1684x\nBogoMIPS\t: 100.00\n"
	fr := &fakeFileReader{files: map[string]string{
		"/proc/cpuinfo":                                cpuinfo,
		"/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq": "2300000\n",
	}}
	c := NewCollector(fr, nil)
	cpu := c.CPUInfo()
	if cpu.Cores != 8 {
		t.Errorf("CPU.Cores = %v, want 8", cpu.Cores)
	}
	if cpu.Frequency != 2300 {
		t.Errorf("CPU.Frequency = %d, want 2300 (MHz)", cpu.Frequency)
	}
	if cpu.Type != "bm1684x" {
		t.Errorf("CPU.Type = %q, want %q", cpu.Type, "bm1684x")
	}
}

func TestCPUInfoMissing(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{}}
	c := NewCollector(fr, nil)
	cpu := c.CPUInfo()
	if cpu.Cores != 0 || cpu.Frequency != 0 || cpu.Type != "" {
		t.Errorf("CPUInfo = %+v, want zero values when missing", cpu)
	}
}

// ---------------------------------------------------------------
// CPUUtilization — /proc/stat 双采样 (total-idle)/total*100
// 真值夹具：t0/t1 delta total=80, idle=79 → 1.25%
// ---------------------------------------------------------------

func TestCPUUtilization(t *testing.T) {
	t0 := "cpu  566567 1769 1009354 261300716 18740 0 166149 0 0 0\n"
	t1 := "cpu  566567 1769 1009355 261300795 18740 0 166149 0 0 0\n"
	fr := &seqFileReader{seq: map[string][]string{
		"/proc/stat": {t0, t1},
	}}
	c := NewCollectorWithSleep(fr, nil, noopSleeper{})
	got := c.CPUInfo().UtilizationRate
	want := 1.25
	if got != want {
		t.Errorf("CPUUtilization = %v, want %v", got, want)
	}
}

func TestCPUUtilizationMissing(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{}}
	c := NewCollectorWithSleep(fr, nil, noopSleeper{})
	if got := c.CPUInfo().UtilizationRate; got != 0 {
		t.Errorf("CPUUtilization = %v, want 0 when missing", got)
	}
}

// TestArchARM64 验证 runtime.GOARCH 映射：arm64 → aarch64
func TestArchMapping(t *testing.T) {
	if v := mapArch("arm64"); v != "aarch64" {
		t.Errorf("mapArch(arm64) = %q, want aarch64", v)
	}
	if v := mapArch("amd64"); v != "x86_64" {
		t.Errorf("mapArch(amd64) = %q, want x86_64", v)
	}
	if v := mapArch("mips"); v != "mips" {
		t.Errorf("mapArch(mips) = %q, want mips (passthrough)", v)
	}
}
