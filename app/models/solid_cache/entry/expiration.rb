# frozen_string_literal: true

module SolidCache
  class Entry
    # Expiration Concern 负责处理缓存条目的过期逻辑。
    # 它提供了根据配置的策略 (最大条目数、最大总大小、最大存活时间)
    # 来查找和删除过期条目的方法。
    module Expiration
      extend ActiveSupport::Concern

      class_methods do
        # 对外暴露的过期方法。
        # 根据传入的参数查找并删除过期条目。
        # `count`: 本次最多删除多少条。
        def expire(count, max_age:, max_entries:, max_size:)
          # 查找符合过期条件的候选条目 ID。
          if (ids = expiry_candidate_ids(count, max_age: max_age, max_entries: max_entries, max_size: max_size)).any?
            # 批量删除。
            delete(ids)
          end
        end

        private
          # 检查缓存是否已满 (根据条目数或总大小判断)。
          def cache_full?(max_entries:, max_size:)
            # 如果配置了 max_entries 且估计的 ID 范围超过了限制。
            if max_entries && max_entries < id_range
              true
            # 如果配置了 max_size 且估计的总大小超过了限制。
            elsif max_size && max_size < estimated_size
              true
            else
              false
            end
          end

          # 查找符合过期条件的候选条目 ID。
          def expiry_candidate_ids(count, max_age:, max_entries:, max_size:)
            # 判断缓存是否已满。
            cache_full = cache_full?(max_entries: max_entries, max_size: max_size)
            # 如果缓存未满且没有设置 max_age，则无需过期，返回空数组。
            return [] unless cache_full || max_age

            # 为了减少并发过期操作处理相同条目的冲突，先获取比目标数量更多的候选者 (3倍)。
            retrieve_count = count * 3

            # 禁用查询缓存，直接查询数据库。
            uncached do
              # 按 ID 排序获取最早插入的 `retrieve_count` 条记录作为初步候选者。
              # 假设 ID 是自增的，这近似于按创建时间排序。
              candidates = order(:id).limit(retrieve_count)

              # 如果缓存已满，则所有初步候选者都符合条件。
              candidate_ids = if cache_full
                candidates.pluck(:id)
              else
                # 如果缓存未满，则只考虑超过 max_age 的条目。
                min_created_at = max_age.seconds.ago
                # 虽然没有 created_at 索引，但按 ID 排序获取的记录大致也是按创建时间排序的。
                # 在内存中过滤掉未到期的记录。
                candidates.pluck(:id, :created_at)
                          .filter_map { |id, created_at| id if created_at < min_created_at }
              end

              # 从最终的候选 ID 列表中随机采样 `count` 个 ID，进一步减少并发冲突。
              candidate_ids.sample(count)
            end
          end
      end
    end
  end
end
