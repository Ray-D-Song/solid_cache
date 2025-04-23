# frozen_string_literal: true

module SolidCache
  class Store
    # Expiry 模块负责触发缓存过期检查。
    # 它不是直接执行删除，而是根据写入操作的频率来决定何时以及如何安排过期任务。
    module Expiry
      # 每写入 N 条记录，就尝试删除 N * EXPIRY_MULTIPLIER 条记录。
      # 这旨在对缓存大小施加持续的"向下压力"。
      EXPIRY_MULTIPLIER = 2

      # 配置项：
      # expiry_batch_size: 每次过期任务处理多少条记录。
      # expiry_method: 使用 :thread (Store 内部线程池) 还是 :job (Active Job) 来执行过期任务。
      # expiry_queue: 如果使用 :job，指定 Active Job 队列名称。
      # expires_per_write: 根据 expiry_batch_size 和 EXPIRY_MULTIPLIER 计算出的每次写入触发过期检查的概率因子。
      # max_age, max_entries, max_size: 传递给 Entry.expire 的过期策略参数。
      attr_reader :expiry_batch_size, :expiry_method, :expiry_queue, :expires_per_write, :max_age, :max_entries, :max_size

      def initialize(options = {})
        super(options)
        @expiry_batch_size = options.fetch(:expiry_batch_size, 100)
        @expiry_method = options.fetch(:expiry_method, :thread)
        @expiry_queue = options.fetch(:expiry_queue, :default)
        # 计算每次写入平均触发多少次过期批处理。
        @expires_per_write = (1 / expiry_batch_size.to_f) * EXPIRY_MULTIPLIER
        @max_age = options.fetch(:max_age, 2.weeks.to_i) # 默认最大存活时间 2 周
        @max_entries = options.fetch(:max_entries, nil)
        @max_size = options.fetch(:max_size, nil)

        raise ArgumentError, "Expiry method must be one of `:thread` or `:job`" unless [ :thread, :job ].include?(expiry_method)
      end

      # 在 Entries 模块的写入操作后调用，用于追踪写入次数并触发过期检查。
      def track_writes(count)
        # 根据写入次数 `count` 和 `expires_per_write` 因子，计算需要触发多少个过期批处理任务。
        expiry_batches(count).times { expire_later }
      end

      private
        # 计算基于写入次数 `count` 需要触发的过期批处理任务数量。
        # 包含一个随机因子，以处理小数部分的概率。
        def expiry_batches(count)
          batches = (count * expires_per_write).floor
          overflow_batch_chance = count * expires_per_write - batches
          batches += 1 if rand < overflow_batch_chance
          batches
        end

        # 安排一个过期任务稍后执行。
        def expire_later
          # 将过期策略参数打包。
          max_options = { max_age: max_age, max_entries: max_entries, max_size: max_size }
          if expiry_method == :job
            # 使用 Active Job 安排 ExpiryJob 任务。
            ExpiryJob
              .set(queue: expiry_queue)
              .perform_later(expiry_batch_size, shard: Entry.current_shard, **max_options)
          else
            # 使用 Store 内部的线程池 (通过 Execution 模块的 async 方法) 安排任务。
            # 直接调用 Entry.expire。
            async { Entry.expire(expiry_batch_size, **max_options) }
          end
        end
    end
  end
end
