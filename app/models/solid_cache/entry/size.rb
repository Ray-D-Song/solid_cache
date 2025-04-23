# frozen_string_literal: true

module SolidCache
  class Entry
    # Size Concern 提供了与缓存条目大小 (byte_size 字段) 相关的功能。
    # 包括查询作用域和估算整个缓存的总大小。
    module Size
      extend ActiveSupport::Concern

      included do
        # 查询作用域：按 byte_size 降序排列，获取最大的 N 条记录的 byte_size。
        scope :largest_byte_sizes, -> (limit) { from(order(byte_size: :desc).limit(limit).select(:byte_size)) }
        # 查询作用域：获取 key_hash 在指定范围内的记录。
        scope :in_key_hash_range, -> (range) { where(key_hash: range) }
        # 查询作用域：获取 byte_size 小于等于指定值的记录。
        scope :up_to_byte_size, -> (cutoff) { where("byte_size <= ?", cutoff) }
      end

      class_methods do
        # 估算缓存的总大小。
        # 使用 MovingAverageEstimate 类 (可能定义在 size/ 目录下) 进行估算。
        # `samples` 参数控制用于估算的样本数量，从全局配置获取。
        def estimated_size(samples: SolidCache.configuration.size_estimate_samples)
          # 需要查找 MovingAverageEstimate 的具体实现来了解估算方法。
          MovingAverageEstimate.new(samples: samples).size
        end
      end
    end
  end
end
