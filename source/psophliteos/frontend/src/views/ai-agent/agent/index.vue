<template>
  <div class="p-4">
    <a-card :bordered="false">
      <template #title>
        <a-space>
          <span>AI Agent</span>
          <a-tag v-if="port" color="green">端口 {{ port }}</a-tag>
          <a-tag v-else color="orange">端口探测中</a-tag>
        </a-space>
      </template>
      <template #extra>
        <a-space>
          <a-button size="small" :loading="detecting" @click="init">重新探测</a-button>
        </a-space>
      </template>

      <div v-if="!ready" class="flex items-center justify-center" style="min-height: 200px">
        <a-spin :spinning="detecting" size="large">
          <div class="text-gray-400">正在探测 picoclaw 服务…</div>
        </a-spin>
      </div>

      <div v-else-if="frameSrc" class="overflow-hidden rounded border border-gray-200">
        <iframe
          :src="frameSrc"
          class="w-full"
          style="height: calc(100vh - 260px); border: none"
          frameborder="0"
        ></iframe>
      </div>

      <a-alert
        v-else
        type="warning"
        show-icon
        message="未检测到 picoclaw 服务"
        description="请确认设备上 picoclaw 已启动（默认端口 18800），或先到「API 配置」页保存配置。"
      />
    </a-card>
  </div>
</template>

<script lang="ts" setup>
  // @ts-nocheck
  import { ref, onMounted } from 'vue';
  import { Card, Space, Tag, Button, Spin, Alert } from 'ant-design-vue';
  import { detectPicoclawPort } from '/@/api/aiAgent';

  const ACard = Card;
  const ASpace = Space;
  const ATag = Tag;
  const AButton = Button;
  const ASpin = Spin;
  const AAlert = Alert;

  const port = ref<number | null>(null);
  const detecting = ref(false);
  const ready = ref(false);

  const frameSrc = ref('');

  async function init() {
    detecting.value = true;
    ready.value = false;
    const p = await detectPicoclawPort();
    port.value = p;
    ready.value = true;
    if (p) {
      // iframe 直连 picoclaw web（/api 绝对路径前端，端口可直连；优先于同源反代）
      frameSrc.value = `http://${window.location.hostname}:${p}/`;
    } else {
      frameSrc.value = '';
    }
    detecting.value = false;
  }

  onMounted(init);
</script>
