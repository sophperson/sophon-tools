package metrics

import "testing"

func TestVPUUsageCv84x6(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{
		"/proc/cpuinfo": "model name	: cv84x6\n",
		"/proc/soph/vpuinfo": `{"enc": {"link_num":3, "usage":40%}
{"dec_0": {"link_num":2, "usage":50%}
{"dec_1": {"link_num":4, "usage":60%}`,
	}}
	c := NewCollector(fr, nil)
	enc, dec, encLinks, decLinks, ok := c.VPUUsage()
	if !ok {
		t.Fatal("VPUUsage() returned ok=false for cv84x6")
	}
	if enc != 40 || dec != 55 {
		t.Errorf("VPUUsage enc=%d dec=%d, want 40/55", enc, dec)
	}
	if encLinks != 3 || decLinks != 6 {
		t.Errorf("VPUUsage links enc=%d dec=%d, want 3/6", encLinks, decLinks)
	}
}

func TestVPUUsageCv84x6SophInfo(t *testing.T) {
	// 对齐方案 §4.4：vc_drv 输出 JSON 行，字段名不敏感，仅 link_num/usage 正则参与解析。
	// 行数要求与 bm1688 分支一致（3 行：enc + 2 dec），enc 在首行。
	fr := &fakeFileReader{files: map[string]string{
		"/proc/cpuinfo": "model name	: cv84x6\n",
		"/proc/soph/vpuinfo": `{"venc_coreid":0, "link_num":3, "usage(instant|long)":40%|10%, "fps":30, "status:Engaged"}
{"vdec_coreid":1, "link_num":2, "usage(instant|long)":50%|20%, "fps":30, "status:IDLE"}
{"vdec_coreid":2, "link_num":4, "usage(instant|long)":60%|30%, "fps":30, "status:IDLE"}`,
	}}
	c := NewCollector(fr, nil)
	enc, dec, encLinks, decLinks, ok := c.VPUUsage()
	if !ok {
		t.Fatal("VPUUsage() returned ok=false for cv84x6 soph format")
	}
	if enc != 40 || dec != 55 {
		t.Errorf("VPUUsage enc=%d dec=%d, want enc=40 dec=55", enc, dec)
	}
	if encLinks != 3 || decLinks != 6 {
		t.Errorf("VPUUsage links enc=%d dec=%d, want 3/6", encLinks, decLinks)
	}
}

func TestTPUFrequencyClkCv84x6(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{
		"/proc/cpuinfo": "model name	: cv84x6\n",
		"/sys/kernel/debug/clk/clk_tpu_ip/clk_rate": "1000000000\n",
	}}
	c := NewCollector(fr, nil)
	if got := c.TPUFrequencyClk(); got != 1000 {
		t.Errorf("TPUFrequencyClk() = %d, want 1000 MHz", got)
	}
}

func TestVPUFrequencyCv84x6(t *testing.T) {
	// clk_ve_axi 是 AXI 总线时钟，语义与 bm1688 cam0pll 不同，不 ÷2。
	fr := &fakeFileReader{files: map[string]string{
		"/proc/cpuinfo": "model name	: cv84x6\n",
		"/sys/kernel/debug/clk/clk_ve_axi/clk_rate": "500000000\n",
	}}
	c := NewCollector(fr, nil)
	if got := c.VPUFrequency(); got != 500 {
		t.Errorf("VPUFrequency() = %d, want 500 MHz (no /2)", got)
	}
}

func TestCPUFrequencyClkCv84x6(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{
		"/proc/cpuinfo": "model name	: cv84x6\n",
		"/sys/kernel/debug/clk/clk_ap_ca55/clk_rate": "1500000000\n",
	}}
	c := NewCollector(fr, nil)
	if got := c.CPUFrequencyClk(); got != 1500 {
		t.Errorf("CPUFrequencyClk() = %d, want 1500 MHz", got)
	}
}

func TestVPUUsageBM1684X(t *testing.T) {
	// BM1684X: 3 entries, enc at index 2 (last). Rust: enc=percentages[2], dec=avg([0..2]).
	fr := &fakeFileReader{files: map[string]string{
		"/proc/cpuinfo": "model name	: bm1684x\n",
		"/proc/vpuinfo": `{"dec_0": {"link_num":5, "usage":20%}
{"dec_1": {"link_num":7, "usage":10%}
{"enc": {"link_num":12, "usage":30%}`,
	}}
	c := NewCollector(fr, nil)
	enc, dec, encLinks, decLinks, ok := c.VPUUsage()
	if !ok {
		t.Fatal("VPUUsage() returned ok=false for bm1684x")
	}
	if enc != 30 || dec != 15 {
		t.Errorf("VPUUsage enc=%d dec=%d, want enc=30 dec=15", enc, dec)
	}
	if encLinks != 12 || decLinks != 12 {
		t.Errorf("VPUUsage links enc=%d dec=%d, want enc=12 dec=12", encLinks, decLinks)
	}
}

func TestVPUUsageBM1688(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{
		"/proc/cpuinfo":          "model name	: BM1688\n",
		"/proc/soph/vpuinfo": `{"enc": {"link_num":3, "usage":40%}
{"dec_0": {"link_num":2, "usage":50%}
{"dec_1": {"link_num":4, "usage":60%}`,
	}}
	c := NewCollector(fr, nil)
	enc, dec, encLinks, decLinks, ok := c.VPUUsage()
	if !ok {
		t.Fatal("VPUUsage() returned ok=false for bm1688")
	}
	if enc != 40 || dec != 55 {
		t.Errorf("VPUUsage enc=%d dec=%d, want 40/55", enc, dec)
	}
	if encLinks != 3 || decLinks != 6 {
		t.Errorf("VPUUsage links enc=%d dec=%d, want 3/6", encLinks, decLinks)
	}
}

func TestVPUUsageMissing(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{
		"/proc/cpuinfo": "model name	: bm1684x\n",
		// vpuinfo 缺失
	}}
	c := NewCollector(fr, nil)
	_, _, _, _, ok := c.VPUUsage()
	if ok {
		t.Error("VPUUsage() should return ok=false when vpuinfo is missing")
	}
}

func TestVPPUsage(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{
		"/proc/cpuinfo": "model name	: bm1684x\n",
		"/proc/vppinfo": "30%|########\n50%|##########\n70%|########",
	}}
	c := NewCollector(fr, nil)
	got := c.VPPUsage()
	if got != 50 {
		t.Errorf("VPPUsage() = %d, want 50 (avg of 30,50,70)", got)
	}
}

func TestVPPUsageMissing(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{}}
	c := NewCollector(fr, nil)
	if got := c.VPPUsage(); got != 0 {
		t.Errorf("VPPUsage() = %d, want 0 when missing", got)
	}
}

func TestJPUUsage(t *testing.T) {
	fr := &fakeFileReader{files: map[string]string{
		"/proc/cpuinfo": "model name	: bm1684x\n",
		"/proc/jpuinfo": "25%|#####\n75%|###############",
	}}
	c := NewCollector(fr, nil)
	got := c.JPUUsage()
	if got != 50 {
		t.Errorf("JPUUsage() = %d, want 50 (avg of 25,75)", got)
	}
}
