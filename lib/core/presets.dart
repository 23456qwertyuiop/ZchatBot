import 'models.dart';

/// Built-in vendors. Adding one is a single line — the app needs nothing else.
/// Every vendor except Anthropic speaks the OpenAI chat-completions protocol.
class Preset {
  const Preset(this.name, this.baseUrl, this.models,
      {this.protocol = Protocol.openai});
  final String name;
  final String baseUrl;
  final List<String> models;
  final Protocol protocol;

  Provider create() => Provider(
        id: newId(),
        name: name,
        protocol: protocol,
        baseUrl: baseUrl,
        models: [...models],
      );
}

const presets = <Preset>[
  // International
  Preset('OpenAI', 'https://api.openai.com/v1', ['gpt-5', 'gpt-5-mini', 'gpt-4.1']),
  Preset('Anthropic', 'https://api.anthropic.com/v1',
      ['claude-sonnet-4-5', 'claude-opus-4-1', 'claude-haiku-4-5'],
      protocol: Protocol.anthropic),
  Preset('Google Gemini', 'https://generativelanguage.googleapis.com/v1beta/openai',
      ['gemini-2.5-pro', 'gemini-2.5-flash']),
  Preset('xAI Grok', 'https://api.x.ai/v1', ['grok-4', 'grok-3-mini']),
  Preset('Mistral', 'https://api.mistral.ai/v1', ['mistral-large-latest', 'mistral-small-latest']),
  Preset('Groq', 'https://api.groq.com/openai/v1', ['llama-3.3-70b-versatile']),
  Preset('OpenRouter', 'https://openrouter.ai/api/v1', ['openai/gpt-5', 'anthropic/claude-sonnet-4.5']),
  // China
  Preset('DeepSeek', 'https://api.deepseek.com/v1', ['deepseek-chat', 'deepseek-reasoner']),
  Preset('通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      ['qwen-max', 'qwen-plus', 'qwen-turbo']),
  Preset('Kimi', 'https://api.moonshot.cn/v1', ['kimi-k2-turbo-preview', 'kimi-latest']),
  Preset('智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4', ['glm-4.6', 'glm-4.5-air', 'glm-4-flash']),
  Preset('豆包', 'https://ark.cn-beijing.volces.com/api/v3', ['doubao-seed-1-6-250615']),
  Preset('MiniMax', 'https://api.minimaxi.com/v1', ['MiniMax-M2']),
  Preset('文心一言', 'https://qianfan.baidubce.com/v2', ['ernie-4.5-turbo-128k']),
  Preset('腾讯混元', 'https://api.hunyuan.cloud.tencent.com/v1', ['hunyuan-turbos-latest']),
  Preset('阶跃星辰', 'https://api.stepfun.com/v1', ['step-2-16k']),
  Preset('硅基流动', 'https://api.siliconflow.cn/v1',
      ['deepseek-ai/DeepSeek-V3', 'Qwen/Qwen3-235B-A22B']),
  // Local / anything else
  Preset('Ollama', 'http://localhost:11434/v1', ['llama3.2']),
  Preset('自定义', '', []),
];
