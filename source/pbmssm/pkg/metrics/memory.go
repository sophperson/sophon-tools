package metrics

import (
	"strconv"
	"strings"
)

// memInfoPath /proc/meminfo 路径常量。
const memInfoPath = "/proc/meminfo"

// Memory 读取 /proc/meminfo 的 MemTotal/MemFree/MemAvailable，kB → MB（对齐 bmssm）。
// 各字段缺失时单独返 0，不阻断。
func (c *Collector) Memory() Memory {
	content := c.readStr(memInfoPath)
	m := Memory{}
	if content == "" {
		return m
	}
	for _, line := range strings.Split(content, "\n") {
		switch {
		case strings.HasPrefix(line, "MemTotal:"):
			m.Total = memLineMB(line)
		case strings.HasPrefix(line, "MemFree:"):
			m.Free = memLineMB(line)
		case strings.HasPrefix(line, "MemAvailable:"):
			m.Available = memLineMB(line)
		}
	}
	return m
}

// MemoryUsagePercent 计算内存使用百分比 (0-100)。
// 使用率 = (total - available) / total * 100，基于 MemAvailable：
// buff/cache 部分可随时回收，不计入真实占用（否则常驻 90%+，无告警价值）。
// 与告警 memUsage 口径一致；MemAvailable 缺失时退化为 MemFree。
func (c *Collector) MemoryUsagePercent() float64 {
	m := c.Memory()
	if m.Total <= 0 {
		return 0
	}
	avail := m.Available
	if avail <= 0 {
		avail = m.Free
	}
	return (m.Total - avail) / m.Total * 100.0
}

// memLineMB 从形如 "MemTotal:       6427708 kB" 的行提取 kB 并转 MB。
// 对齐 bmssm/pget_info：整数除法（截断），如 6427708 kB → 6277 MB。
func memLineMB(line string) float64 {
	// "MemTotal:" 前缀后，取第一个数字段
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return 0
	}
	v, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil {
		return 0
	}
	return float64(v / 1024) // 整数除法，对齐 bmssm
}
