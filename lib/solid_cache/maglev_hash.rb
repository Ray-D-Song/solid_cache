# frozen_string_literal: true

# 实现了 Google 的 Maglev 一致性哈希算法。
# 论文参考: https://static.googleusercontent.com/media/research.google.com/en//pubs/archive/44824.pdf
# Maglev 旨在提供更好的一致性 (节点增减时，最小化 key 的重新分布) 和负载均衡。

module SolidCache
  class MaglevHash
    attr_reader :nodes

    # Maglev 哈希表的大小 M，必须是素数。
    # 这个值影响哈希分布的均匀性和查找性能。
    TABLE_SIZE = 2053

    # 初始化。
    # `nodes`: 节点 (分片) 名称的数组。
    def initialize(nodes)
      raise ArgumentError, "No nodes specified" if nodes.count == 0
      # 节点数量不能超过哈希表大小。
      raise ArgumentError, "Maximum node count is #{TABLE_SIZE}" if nodes.count > TABLE_SIZE

      # 确保节点唯一并排序，这对于一致性哈希的稳定性很重要。
      @nodes = nodes.uniq.sort
      # 构建查找表 (lookup table)。
      @lookup = build_lookup
    end

    # 根据给定的 key 查找对应的节点名称。
    def node(key)
      # 1. 使用快速哈希函数 (CRC32) 计算 key 的哈希值。
      # 2. 对哈希值取模，得到在查找表中的索引。
      # 3. 从查找表中获取该索引对应的节点索引。
      # 4. 根据节点索引返回节点名称。
      nodes[lookup[quick_hash(key) % TABLE_SIZE]]
    end

    private
      attr_reader :lookup, :node_count

      # 构建 Maglev 查找表 (lookup table)。
      # 这个表的大小是 TABLE_SIZE，每个位置存储一个指向 nodes 数组的索引。
      def build_lookup
        # 初始化查找表，所有位置为 nil。
        lookup = Array.new(TABLE_SIZE, nil)

        # 为每个节点生成其偏好列表 (preference list)。
        node_preferences = nodes.map { |node| build_preferences(node) }
        node_count = nodes.count

        # 填充查找表。
        # 循环直到查找表被填满。
        TABLE_SIZE.times do |i|
          # 轮流选择下一个节点。
          node_index = i % node_count
          # 获取该节点的偏好列表。
          preferences = node_preferences[node_index]
          # 从偏好列表中找到第一个尚未被占用的槽位 (slot)。
          slot = preferences.preferred_free_slot(lookup)
          # 将该槽位分配给当前节点。
          lookup[slot] = node_index
        end

        lookup
      end

      # 为单个节点构建偏好列表 (preference list)。
      # 偏好列表决定了该节点倾向于填充查找表中的哪些位置。
      # 使用两个独立的哈希函数 (基于 MD5) 计算 offset 和 skip。
      def build_preferences(node)
        # offset 决定了偏好列表的起始位置。
        offset = md5(node, :offset) % TABLE_SIZE
        # skip 决定了在偏好列表中查找下一个位置的步长。
        skip = md5(node, :skip) % (TABLE_SIZE - 1) + 1

        # 创建 Preferences 对象来管理该节点的偏好列表。
        Preferences.new(offset, skip)
      end

      # 使用 MD5 计算哈希值，并取其前 4 个字节 (无符号长整型)。
      # 用于生成 offset 和 skip。
      def md5(*args)
        ::Digest::MD5.digest(args.join).unpack1("L>")
      end

      # 快速哈希函数，用于将任意 key 映射到查找表的索引范围。
      # 使用 CRC32，因为它通常比 MD5 快。
      def quick_hash(key)
        Zlib.crc32(key.to_s)
      end

      # Preferences 类用于管理单个节点的偏好列表。
      class Preferences
        # 根据 offset 和 skip 生成完整的偏好列表 (包含 TABLE_SIZE 个槽位索引)。
        def initialize(offset, skip)
          @preferred_slots = TABLE_SIZE.times.map { |i| (offset + i * skip) % TABLE_SIZE }
          @rank = 0 # 记录当前查找偏好列表的位置。
        end

        # 从偏好列表中找到下一个可用的 (未被其他节点占用的) 槽位。
        def preferred_free_slot(lookup)
          loop do
            slot = next_slot
            return slot if lookup[slot].nil? # 如果该槽位未被占用，则返回。
          end
        end

        private
          attr_reader :rank, :preferred_slots

          # 获取偏好列表中的下一个槽位索引，并递增 rank。
          def next_slot
            preferred_slots[rank].tap { @rank += 1 }
          end
      end
  end
end
