# frozen_string_literal: true

module SolidCache
  class Store
    # Stats 模块提供了获取缓存统计信息的功能。
    module Stats
      def initialize(options = {})
        super(options)
      end

      # 返回包含缓存统计信息的哈希。
      def stats
        {
          connections: connections.count, # 分片/连接的数量
          connection_stats: connections_stats # 每个分片的详细统计信息
        }
      end

      private
        # 获取每个分片的统计信息。
        # 使用 with_each_connection 遍历所有分片连接。
        def connections_stats
          # `with_each_connection` 返回一个枚举器，`to_h` 将其转换为哈希。
          # 块的返回值是 [ shard_name, stats_hash ]。
          with_each_connection.to_h { |connection| [ Entry.current_shard, connection_stats ] }
        end

        # 获取当前连接 (分片) 的详细统计信息。
        def connection_stats
          # 获取当前分片中最旧的记录的创建时间。
          oldest_created_at = Entry.order(:id).pick(:created_at)

          {
            max_age: max_age, # 配置的最大存活时间
            oldest_age: oldest_created_at ? Time.now - oldest_created_at : nil, # 最旧记录的实际存活时间
            max_entries: max_entries, # 配置的最大条目数
            entries: Entry.id_range # 当前分片中的估计条目数 (基于 ID 范围)
            # 注意：这里没有报告 max_size 和 estimated_size。
          }
        end
    end
  end
end
