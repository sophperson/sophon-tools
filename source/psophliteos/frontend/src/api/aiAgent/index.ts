import { defHttp } from '/@/utils/http/axios';

// Agent 配置相关接口。
// - LLM/VLM 配置 + 转发 key 管理：走 bmssm /api/v1/llm-proxy/*（经 sophliteos 反代）
// - 端口探测/转发：sophliteos 本地端点 /api/device/ai-agent/*
// defHttp 自动加 /api 前缀。
enum Api {
  LlmProxyConfig = '/v1/llm-proxy/config',
  LlmProxyModels = '/v1/llm-proxy/models',
  ForwardKeyReset = '/v1/llm-proxy/forward-key/reset',
  ForwardKeyWrite = '/v1/llm-proxy/forward-key/write-picoclaw',
  LlmProxyTest = '/v1/llm-proxy/test',
  Port = '/device/ai-agent/port',
}

export interface TestResult {
  name: string;
  ok: boolean;
  message: string;
}

export interface TestResponse {
  results: TestResult[];
  allOk: boolean;
}

export interface AgentConfig {
  llmApiBase: string;
  llmModel: string;
  llmEnabled: boolean;
  llmHasKey: boolean;
  vlmApiBase: string;
  vlmModel: string;
  vlmEnabled: boolean;
  vlmHasKey: boolean;
  forwardKey: string;
  forwardKeyReady: boolean;
  updatedAt?: string;
}

// 读取已存配置（bmssm）；无则返回 null。
export async function getAgentConfig(): Promise<AgentConfig | null> {
  try {
    const res = await defHttp.get<AgentConfig>(
      { url: Api.LlmProxyConfig },
      { isTransformResponse: false }
    );
    const data = (res as any)?.result ?? res;
    return data && typeof data === 'object' && 'llmApiBase' in data ? (data as AgentConfig) : null;
  } catch {
    return null;
  }
}

// 保存 LLM/VLM 配置（key 为空表示不修改）。
export async function saveAgentConfig(cfg: {
  llmApiBase: string;
  llmApiKey: string;
  llmModel: string;
  llmEnabled: boolean;
  vlmApiBase: string;
  vlmApiKey: string;
  vlmModel: string;
  vlmEnabled: boolean;
}): Promise<{ ok: boolean; message?: string }> {
  try {
    const res = await defHttp.put(
      { url: Api.LlmProxyConfig, data: cfg },
      { isTransformResponse: false }
    );
    const data = (res as any)?.result ?? res;
    if (data && typeof data === 'object' && 'llmApiBase' in data) {
      return { ok: true };
    }
    return { ok: false, message: (res as any)?.error_message || (res as any)?.msg || '保存失败' };
  } catch (e: any) {
    return { ok: false, message: e?.message || '保存失败' };
  }
}

// 从供应商拉取模型列表（kind=llm|vlm）。
export async function getProviderModels(kind: 'llm' | 'vlm'): Promise<string[]> {
  try {
    const res = await defHttp.get<{ models: { id: string }[] }>(
      { url: Api.LlmProxyModels, params: { kind } },
      { isTransformResponse: false }
    );
    const data = (res as any)?.result ?? res;
    const list = data?.models;
    return Array.isArray(list) ? list.map((m: any) => m?.id ?? m).filter(Boolean) : [];
  } catch {
    return [];
  }
}

// 重置转发 key。
export async function resetForwardKey(): Promise<{ ok: boolean; key?: string; message?: string }> {
  try {
    const res = await defHttp.post(
      { url: Api.ForwardKeyReset },
      { isTransformResponse: false }
    );
    const data = (res as any)?.result ?? res;
    if (data && typeof data === 'object' && data.forwardKey) {
      return { ok: true, key: data.forwardKey };
    }
    return { ok: false, message: (res as any)?.error_message || '重置失败' };
  } catch (e: any) {
    return { ok: false, message: e?.message || '重置失败' };
  }
}

// 写入本地 picoclaw。
export async function writeForwardKeyToPicoclaw(): Promise<{ ok: boolean; message?: string }> {
  try {
    const res = await defHttp.post(
      { url: Api.ForwardKeyWrite },
      { isTransformResponse: false }
    );
    const data = (res as any)?.result ?? res;
    if (data && typeof data === 'object' && data.ok) {
      return { ok: true };
    }
    return { ok: false, message: (res as any)?.error_message || '写入失败' };
  } catch (e: any) {
    return { ok: false, message: e?.message || '写入失败' };
  }
}

// 探测 picoclaw web 端口（本地端点）。
export async function detectPicoclawPort(): Promise<number | null> {
  try {
    const res = await defHttp.get<{ port: number }>(
      { url: Api.Port },
      { isTransformResponse: false }
    );
    const data = (res as any)?.result ?? res;
    if (data && typeof data === 'object' && typeof data.port === 'number') {
      return data.port;
    }
    return null;
  } catch {
    return null;
  }
}

// 一键测试：带图分发 + LLM 推理。
export async function testAgentConfig(): Promise<{ ok: boolean; data?: TestResponse; message?: string }> {
  try {
    const res = await defHttp.post<TestResponse>(
      { url: Api.LlmProxyTest },
      { isTransformResponse: false }
    );
    const data = (res as any)?.result ?? res;
    if (data && typeof data === 'object' && 'allOk' in data) {
      return { ok: true, data: data as TestResponse };
    }
    return { ok: false, message: (res as any)?.error_message || '测试失败' };
  } catch (e: any) {
    return { ok: false, message: e?.message || '测试失败' };
  }
}

export { Api as AgentConfigApi };
