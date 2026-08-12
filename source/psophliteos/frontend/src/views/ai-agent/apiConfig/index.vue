<template>
  <div class="p-4">
    <a-card :bordered="false" title="Agent 配置">
      <!-- 页选框：LLM / VLM -->
      <a-radio-group v-model:value="activeKey" button-style="solid" class="mb-4">
        <a-radio-button value="llm">LLM 模型</a-radio-button>
        <a-radio-button value="vlm">VLM 模型</a-radio-button>
      </a-radio-group>

      <!-- LLM 配置（仅选中时渲染） -->
      <a-form
        v-if="activeKey === 'llm'"
        :label-col="{ span: 5 }"
        :wrapper-col="{ span: 16 }"
        class="max-w-2xl"
      >
        <a
          href="https://sophnet.com/"
          target="_blank"
          rel="noopener"
          class="sophnet-promo my-5 block no-underline"
        >
          <div class="flex items-baseline gap-3">
            <span class="sophnet-promo-title">Sophnet</span>
            <span class="sophnet-promo-text">专为开发者打造的 AI 工具平台，让 AI 集成变得简单高效</span>
          </div>
        </a>
        <a-form-item label="API Base URL">
          <a-select
            v-model:value="form.llmApiBaseType"
            style="width: 100%"
            :options="apiBaseOptions"
            @change="onApiBaseChange('llm', $event)"
          />
        </a-form-item>
        <a-form-item label="API Key">
          <a-input-password
            v-model:value="form.llmApiKey"
            :placeholder="form.llmHasKey ? '已配置（留空保持不变）' : '请输入上游 API Key'"
            autocomplete="new-password"
          />
        </a-form-item>
        <a-form-item label="模型名称">
          <a-input-group compact>
            <a-input v-model:value="form.llmModel" style="width: 60%" placeholder="sophnet-deepseek" />
            <a-button style="width: 20%" @click="openModelPicker('llm')">选择</a-button>
          </a-input-group>
        </a-form-item>
        <a-form-item label="启用">
          <a-switch v-model:checked="form.llmEnabled" />
        </a-form-item>
      </a-form>

      <!-- VLM 配置（仅选中时渲染） -->
      <a-form
        v-else-if="activeKey === 'vlm'"
        :label-col="{ span: 5 }"
        :wrapper-col="{ span: 16 }"
        class="max-w-2xl"
      >
        <a
          href="https://sophnet.com/"
          target="_blank"
          rel="noopener"
          class="sophnet-promo my-5 block no-underline"
        >
          <div class="flex items-baseline gap-3">
            <span class="sophnet-promo-title">Sophnet</span>
            <span class="sophnet-promo-text">专为开发者打造的 AI 工具平台，让 AI 集成变得简单高效</span>
          </div>
        </a>
        <a-form-item label="API Base URL">
          <a-select
            v-model:value="form.vlmApiBaseType"
            style="width: 100%"
            :options="apiBaseOptions"
            @change="onApiBaseChange('vlm', $event)"
          />
        </a-form-item>
        <a-form-item label="API Key">
          <a-input-password
            v-model:value="form.vlmApiKey"
            :placeholder="form.vlmHasKey ? '已配置（留空保持不变）' : '请输入上游 API Key'"
            autocomplete="new-password"
          />
        </a-form-item>
        <a-form-item label="模型名称">
          <a-input-group compact>
            <a-input v-model:value="form.vlmModel" style="width: 60%" placeholder="sophnet-vl-flash" />
            <a-button style="width: 20%" @click="openModelPicker('vlm')">选择</a-button>
          </a-input-group>
        </a-form-item>
        <a-form-item label="启用">
          <a-switch v-model:checked="form.vlmEnabled" />
        </a-form-item>
      </a-form>

      <!-- 保存 + 测试 -->
      <div class="mt-4 flex items-center gap-2">
        <a-button type="primary" :loading="saving" @click="handleSave">保存配置</a-button>
        <a-button :loading="testing" @click="handleTest">测试</a-button>
      </div>

      <!-- 测试结果 -->
      <div v-if="testResults.length" class="mt-3 max-w-2xl">
        <a-alert
          :type="testAllOK ? 'success' : 'error'"
          show-icon
          :message="testAllOK ? '测试全部通过' : '部分测试未通过'"
          class="mb-2"
        />
        <div v-for="(r, idx) in testResults" :key="idx" class="mb-2">
          <div class="font-medium">
            <a-tag :color="r.ok ? 'green' : 'red'">{{ r.ok ? '通过' : '失败' }}</a-tag>
            {{ r.name }}
          </div>
          <div class="text-sm text-gray-600 break-all">{{ r.message }}</div>
        </div>
      </div>

      <a-divider />

      <!-- 转发 key 管理 -->
      <div class="mt-4">
        <div class="font-medium mb-2">转发 Key（客户端调用代理的凭据）</div>
        <a-alert
          v-if="form.forwardKeyReady"
          type="success"
          show-icon
          message="已写入本地 picoclaw（devproxy.key）"
          class="mb-2"
        />
        <a-input-group compact class="max-w-xl">
          <a-input
            v-model:value="form.forwardKey"
            read-only
            style="width: 60%"
            placeholder="转发 key 尚未生成"
          />
          <a-button style="width: 12%" @click="copyForwardKey">拷贝</a-button>
          <a-button style="width: 12%" :loading="resetting" @click="handleResetKey">重置</a-button>
          <a-button
            style="width: 16%"
            type="primary"
            :loading="writing"
            @click="handleWriteKey"
            >写入本地</a-button
          >
        </a-input-group>
        <div class="text-gray-400 text-xs mt-1">
          重置会生成新 key；「写入本地」将覆盖 /opt/sophon/picoclaw/.picoclaw/devproxy.key 并重启 sophpicoclaw 服务
        </div>
      </div>

      <a-divider />

      <!-- 服务监控与管理 -->
      <div class="mt-4">
        <div class="mb-2 flex items-center justify-between">
          <span class="font-medium">服务管理（sophpicoclaw）</span>
          <a-space>
            <a-button size="small" :loading="svcLoading" @click="refreshService">刷新</a-button>
          </a-space>
        </div>
        <a-card v-if="svc" size="small" class="max-w-2xl">
          <a-descriptions :column="2" size="small">
            <a-descriptions-item label="运行状态">
              <a-tag :color="svc.active ? 'green' : 'red'">
                {{ svc.active ? '运行中' : '已停止' }}
              </a-tag>
            </a-descriptions-item>
            <a-descriptions-item label="开机自启">
              <a-tag :color="svc.enabledState === 'enabled' ? 'green' : 'orange'">
                {{ svc.enabledState === 'enabled' ? '已启用' : '未启用' }}
              </a-tag>
            </a-descriptions-item>
            <a-descriptions-item label="状态">
              {{ svc.activeState || '—' }} / {{ svc.subState || '—' }}
            </a-descriptions-item>
            <a-descriptions-item label="PID">{{ svc.mainPid || '—' }}</a-descriptions-item>
            <a-descriptions-item label="端口">{{ svc.ports.join(', ') }}</a-descriptions-item>
            <a-descriptions-item label="端口可达">
              <a-tag :color="svc.running ? 'green' : 'red'">
                {{ svc.running ? '是' : '否' }}
              </a-tag>
            </a-descriptions-item>
          </a-descriptions>
          <div class="mt-3">
            <a-space>
              <a-button size="small" type="primary" :loading="svcActing" @click="doServiceAction('restart')">重启</a-button>
              <a-button size="small" :loading="svcActing" @click="doServiceAction('start')">启动</a-button>
              <a-button size="small" danger :loading="svcActing" @click="doServiceAction('stop')">停止</a-button>
              <a-button size="small" :loading="svcActing" @click="doServiceAction('enable')">启用自启</a-button>
              <a-button size="small" :loading="svcActing" @click="doServiceAction('disable')">关闭自启</a-button>
            </a-space>
          </div>
          <a-collapse class="mt-2" :bordered="false">
            <a-collapse-panel key="log" header="最近日志">
              <pre class="max-h-48 overflow-auto whitespace-pre-wrap text-xs text-gray-600">{{ svc.logTail || '暂无日志' }}</pre>
            </a-collapse-panel>
          </a-collapse>
        </a-card>
        <a-card v-else size="small" class="max-w-2xl">
          <a-empty description="未获取到服务状态（sophpicoclaw 未安装或 bmssm 不可达）" />
        </a-card>
      </div>
    </a-card>

    <!-- 模型选择弹窗 -->
    <a-modal
      v-model:open="picker.visible"
      :title="`选择 ${picker.kind === 'llm' ? 'LLM' : 'VLM'} 模型`"
      @ok="applyPickedModel"
      :ok-button-props="{ disabled: !picker.selected }"
    >
      <div class="mb-3">
        <a-input-search
          v-model:value="picker.custom"
          placeholder="或手动输入模型名，回车确认"
          enter-button="使用"
          @search="applyCustomModel"
        />
      </div>
      <a-select
        v-model:value="picker.selected"
        style="width: 100%"
        placeholder="从供应商拉取模型列表"
        :loading="picker.loading"
        :options="picker.options"
        @dropdown-visible-change="loadModels"
        allow-clear
      />
    </a-modal>
  </div>
</template>

<script lang="ts" setup>
  // @ts-nocheck
  import { reactive, ref, onMounted } from 'vue';
  import {
    Card,
    Radio,
    Form,
    Input,
    Button,
    Space,
    Switch,
    Divider,
    Alert,
    Modal,
    Select,
    Tag,
    Descriptions,
    Collapse,
    Empty,
    message,
  } from 'ant-design-vue';
  import {
    getAgentConfig,
    saveAgentConfig,
    getProviderModels,
    resetForwardKey,
    writeForwardKeyToPicoclaw,
    testAgentConfig,
    getServiceStatus,
    serviceAction,
    type AgentConfig,
    type TestResult,
    type ServiceStatus,
  } from '/@/api/aiAgent';

  const ACard = Card;
  const ARadioGroup = Radio.Group;
  const ARadioButton = Radio.Button;
  const AForm = Form;
  const AFormItem = Form.Item;
  const AInput = Input;
  const AInputPassword = Input.Password;
  const AInputGroup = Input.Group;
  const AInputSearch = Input.Search;
  const AButton = Button;
  const ASpace = Space;
  const ASwitch = Switch;
  const ADivider = Divider;
  const AAlert = Alert;
  const AModal = Modal;
  const ASelect = Select;
  const ATag = Tag;
  const ADescriptions = Descriptions;
  const ADescriptionsItem = Descriptions.Item;
  const ACollapse = Collapse;
  const ACollapsePanel = Collapse.Panel;
  const AEmpty = Empty;

  const activeKey = ref('llm');
  const saving = ref(false);
  const resetting = ref(false);
  const writing = ref(false);
  const testing = ref(false);
  const testResults = ref<TestResult[]>([]);
  const testAllOK = ref(true);

  // sophpicoclaw 服务监控与管理
  const svc = ref<ServiceStatus | null>(null);
  const svcLoading = ref(false);
  const svcActing = ref(false);

  async function refreshService() {
    svcLoading.value = true;
    try {
      svc.value = await getServiceStatus();
    } finally {
      svcLoading.value = false;
    }
  }

  async function doServiceAction(action: string) {
    if (svcActing.value) return;
    svcActing.value = true;
    try {
      const res = await serviceAction(action);
      if (res.ok) {
        message.success(`操作成功：${action}`);
      } else {
        message.error(res.message || '操作失败');
      }
    } finally {
      svcActing.value = false;
    }
    await refreshService();
  }

  // API Base URL 预设
  const SOPHNET_API_BASE = 'https://www.sophnet.com/api/open-apis/v1';
  const LOCAL_API_BASE = 'http://127.0.0.1:8000/v1';
  const apiBaseOptions = [
    { label: 'Sophnet', value: 'sophnet' },
    { label: '本地模型', value: 'local' },
  ];
  const apiBaseByType: Record<string, string> = {
    sophnet: SOPHNET_API_BASE,
    local: LOCAL_API_BASE,
  };

  const form = reactive({
    llmApiBase: '',
    llmApiBaseType: 'sophnet',
    llmApiKey: '',
    llmModel: '',
    llmEnabled: true,
    llmHasKey: false,
    vlmApiBase: '',
    vlmApiBaseType: 'sophnet',
    vlmApiKey: '',
    vlmModel: '',
    vlmEnabled: true,
    vlmHasKey: false,
    forwardKey: '',
    forwardKeyReady: false,
  });

  // 根据已存 apiBase 推断类型（匹配预设则对应类型，否则兜底 sophnet）
  function inferApiBaseType(apiBase: string): string {
    for (const [type, url] of Object.entries(apiBaseByType)) {
      if (apiBase && apiBase === url) {
        return type;
      }
    }
    return 'sophnet';
  }

  // 下拉切换：自动填充对应 URL（sophnet 固定，不允许自定义）
  function onApiBaseChange(kind: 'llm' | 'vlm', type: string) {
    const url = apiBaseByType[type] || SOPHNET_API_BASE;
    if (kind === 'llm') {
      form.llmApiBase = url;
    } else {
      form.vlmApiBase = url;
    }
  }

  const picker = reactive({
    visible: false,
    kind: 'llm' as 'llm' | 'vlm',
    options: [] as { label: string; value: string }[],
    selected: undefined as string | undefined,
    custom: '',
    loading: false,
  });

  async function init() {
    const cfg: AgentConfig | null = await getAgentConfig();
    if (cfg) {
      form.llmApiBase = cfg.llmApiBase || SOPHNET_API_BASE;
      form.llmApiBaseType = inferApiBaseType(cfg.llmApiBase || '');
      form.llmModel = cfg.llmModel || '';
      form.llmEnabled = cfg.llmEnabled !== false;
      form.llmHasKey = !!cfg.llmHasKey;
      form.vlmApiBase = cfg.vlmApiBase || SOPHNET_API_BASE;
      form.vlmApiBaseType = inferApiBaseType(cfg.vlmApiBase || '');
      form.vlmModel = cfg.vlmModel || '';
      form.vlmEnabled = cfg.vlmEnabled !== false;
      form.vlmHasKey = !!cfg.vlmHasKey;
      form.forwardKey = cfg.forwardKey || '';
      form.forwardKeyReady = !!cfg.forwardKeyReady;
    }
  }

  async function handleSave() {
    if (!form.llmApiBase.trim() && !form.vlmApiBase.trim()) {
      message.warning('LLM 或 VLM 至少配置一个 API Base URL');
      return;
    }
    saving.value = true;
    const res = await saveAgentConfig({
      llmApiBase: form.llmApiBase.trim(),
      llmApiKey: form.llmApiKey,
      llmModel: form.llmModel.trim() || 'sophnet-deepseek',
      llmEnabled: form.llmEnabled,
      vlmApiBase: form.vlmApiBase.trim(),
      vlmApiKey: form.vlmApiKey,
      vlmModel: form.vlmModel.trim() || 'sophnet-vl-flash',
      vlmEnabled: form.vlmEnabled,
    });
    saving.value = false;
    if (res.ok) {
      message.success('配置已保存，转发服务已生效');
      form.llmApiKey = '';
      form.vlmApiKey = '';
      form.llmHasKey = true;
      form.vlmHasKey = true;
    } else {
      message.error(res.message || '保存失败');
    }
  }

  async function handleTest() {
    testing.value = true;
    testResults.value = [];
    const res = await testAgentConfig();
    testing.value = false;
    if (res.ok && res.data) {
      testResults.value = res.data.results || [];
      testAllOK.value = !!res.data.allOk;
    } else {
      testAllOK.value = false;
      testResults.value = [
        { name: '测试', ok: false, message: res.message || '测试请求失败' },
      ];
    }
  }

  // --- 模型选择弹窗 ---
  function openModelPicker(kind: 'llm' | 'vlm') {
    picker.kind = kind;
    picker.selected = undefined;
    picker.custom = '';
    picker.options = [];
    picker.visible = true;
  }

  async function loadModels(open: boolean) {
    if (!open || picker.options.length) return;
    picker.loading = true;
    const ids = await getProviderModels(picker.kind);
    picker.options = ids.map((id) => ({ label: id, value: id }));
    picker.loading = false;
  }

  function applyCustomModel() {
    const v = picker.custom.trim();
    if (!v) return;
    applyModel(v);
  }

  function applyPickedModel() {
    if (picker.selected) {
      applyModel(picker.selected);
    }
  }

  function applyModel(name: string) {
    if (picker.kind === 'llm') {
      form.llmModel = name;
    } else {
      form.vlmModel = name;
    }
    picker.visible = false;
    message.success(`已选择模型 ${name}`);
  }

  // --- 转发 key 操作 ---
  async function copyForwardKey() {
    if (!form.forwardKey) {
      message.warning('转发 key 尚未生成');
      return;
    }
    try {
      await navigator.clipboard.writeText(form.forwardKey);
      message.success('已拷贝到剪贴板');
    } catch {
      // 兼容非 https 环境
      const ta = document.createElement('textarea');
      ta.value = form.forwardKey;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
      message.success('已拷贝到剪贴板');
    }
  }

  async function handleResetKey() {
    resetting.value = true;
    const res = await resetForwardKey();
    resetting.value = false;
    if (res.ok && res.key) {
      form.forwardKey = res.key;
      form.forwardKeyReady = false;
      message.success('转发 key 已重置（尚未写入本地 picoclaw）');
    } else {
      message.error(res.message || '重置失败');
    }
  }

  async function handleWriteKey() {
    if (!form.forwardKey) {
      message.warning('转发 key 尚未生成');
      return;
    }
    writing.value = true;
    const res = await writeForwardKeyToPicoclaw();
    writing.value = false;
    if (res.ok) {
      form.forwardKeyReady = true;
      message.success('已写入本地 picoclaw 并重启');
    } else {
      message.error(res.message || '写入失败');
    }
  }

  onMounted(() => {
    init();
    refreshService();
  });
</script>

<style lang="less" scoped>
  .sophnet-promo {
    // 横幅与上下元素之间留白（my-5 已设 margin，这里定义内边距与视觉）
    padding: 14px 20px;
    border-radius: 10px;
    border: 1px solid #d6e4ff;
    background: linear-gradient(120deg, #eef4ff, #dceaff, #eef4ff);
    background-size: 200% 100%;
    animation: sophnet-gradient 8s ease infinite;
    box-shadow: 0 1px 4px rgba(26, 115, 232, 0.08);
    transition: box-shadow 0.2s ease, border-color 0.2s ease;
    cursor: pointer;
  }

  .sophnet-promo:hover {
    box-shadow: 0 2px 10px rgba(26, 115, 232, 0.18);
    border-color: #b6d0ff;
  }

  .sophnet-promo-title {
    font-size: 18px;
    font-weight: 700;
    color: #1a73e8;
    white-space: nowrap;
  }

  .sophnet-promo-text {
    font-size: 15px;
    color: #3c5a8f;
    line-height: 1.5;
  }

  @keyframes sophnet-gradient {
    0% {
      background-position: 0% 50%;
    }
    50% {
      background-position: 100% 50%;
    }
    100% {
      background-position: 0% 50%;
    }
  }
</style>
