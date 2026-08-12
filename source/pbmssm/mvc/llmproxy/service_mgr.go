package llmproxy

import (
	"fmt"
	"net"
	"strings"
	"time"

	"bmssm/pkg/system"
	sysdpkg "bmssm/pkg/systemd"
)

// sophpicoclawUnit sophpicoclaw 服务名（systemd unit，由出厂部署固定）。
const sophpicoclawUnit = "sophpicoclaw.service"

// sophpicoclawPorts 服务健康探测端口：gateway(18790) 与 web(18800)。
var sophpicoclawPorts = []int{18790, 18800}

// ServiceStatus sophpicoclaw 服务状态快照。
type ServiceStatus struct {
	Active       bool   `json:"active"`
	ActiveState  string `json:"activeState"`
	SubState     string `json:"subState"`
	EnabledState string `json:"enabledState"`
	MainPID      string `json:"mainPid"`
	Ports        []int  `json:"ports"`
	Running      bool   `json:"running"`
	LogTail      string `json:"logTail"`
}

// GetSophpicoclawStatus 汇总 sophpicoclaw 服务状态（systemd + 端口探测 + 日志尾部）。
// 无 systemd 或 unit 未安装时返回空状态，不 panic。
func GetSophpicoclawStatus() (*ServiceStatus, error) {
	st := &ServiceStatus{Ports: sophpicoclawPorts}

	out, _, _ := system.RunCommandArgs("systemctl", "show", sophpicoclawUnit,
		"-p", "ActiveState", "-p", "SubState", "-p", "MainPID")
	for _, line := range strings.Split(out, "\n") {
		kv := strings.SplitN(line, "=", 2)
		if len(kv) != 2 {
			continue
		}
		switch kv[0] {
		case "ActiveState":
			st.ActiveState = kv[1]
		case "SubState":
			st.SubState = kv[1]
		case "MainPID":
			st.MainPID = kv[1]
		}
	}
	st.Active = st.ActiveState == "active"

	if en, _, _ := system.RunCommandArgs("systemctl", "is-enabled", sophpicoclawUnit); en != "" {
		st.EnabledState = strings.TrimSpace(en)
	}

	for _, p := range sophpicoclawPorts {
		if portUp(p) {
			st.Running = true
			break
		}
	}

	if tail, _, _ := system.RunCommandArgs("journalctl", "-u", sophpicoclawUnit, "-n", "20", "--no-pager"); tail != "" {
		st.LogTail = strings.TrimSpace(tail)
	}
	return st, nil
}

// ActionSophpicoclaw 对 sophpicoclaw 执行白名单操作（start/stop/restart/enable/disable）。
// 仅允许操作 sophpicoclaw，经 systemd.Action 的 unit 白名单校验，杜绝注入。
func ActionSophpicoclaw(action string) error {
	allowed := map[string]bool{
		"start": true, "stop": true, "restart": true,
		"enable": true, "disable": true,
	}
	if !allowed[action] {
		return fmt.Errorf("invalid action: %q", action)
	}
	if err := sysdpkg.ValidateUnitName(sophpicoclawUnit); err != nil {
		return err
	}
	return sysdpkg.Action(sophpicoclawUnit, action)
}

// portUp 探测端口是否监听（短超时，不阻塞）。
func portUp(port int) bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 500*time.Millisecond)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}
