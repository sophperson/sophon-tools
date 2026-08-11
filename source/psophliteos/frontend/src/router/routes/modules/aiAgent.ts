import type { AppRouteModule } from '/@/router/types';

import { LAYOUT } from '/@/router/constant';
import { t } from '/@/hooks/web/useI18n';

const aiAgent: AppRouteModule = {
  path: '/ai-agent',
  name: 'AiAgent',
  component: LAYOUT,
  redirect: '/ai-agent/apiConfig',
  meta: {
    orderNo: 4,
    icon: 'bx:bot',
    title: t('routes.dashboard.aiAgent'),
  },
  children: [
    {
      path: 'apiConfig',
      name: 'AiAgentApiConfig',
      component: () => import('/@/views/ai-agent/apiConfig/index.vue'),
      meta: {
        title: t('routes.dashboard.aiAgentApiConfig'),
      },
    },
    {
      path: 'agent',
      name: 'AiAgentAgent',
      component: () => import('/@/views/ai-agent/agent/index.vue'),
      meta: {
        title: t('routes.dashboard.aiAgentAgent'),
      },
    },
  ],
};

export default aiAgent;
