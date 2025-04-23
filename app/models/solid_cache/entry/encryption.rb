# frozen_string_literal: true

module SolidCache
  class Entry
    # Encryption Concern 负责为 Entry 模型的 value 字段添加加密功能。
    module Encryption
      extend ActiveSupport::Concern

      included do
        # 检查全局配置是否启用了加密。
        if SolidCache.configuration.encrypt?
          # 如果启用了加密，则使用 Active Record 的 encrypts 方法对 :value 字段进行加密。
          # 加密选项 (如密钥提供者、确定性等) 从全局配置 `encryption_context_properties` 获取。
          encrypts :value, **SolidCache.configuration.encryption_context_properties
        end
      end
    end
  end
end
