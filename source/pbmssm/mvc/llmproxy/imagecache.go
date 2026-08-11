package llmproxy

import (
	"container/list"
	"sync"
	"time"
)

// imageCache 图片描述缓存：以图片数据哈希为 key，缓存 VLM 生成的描述。
// LRU 淘汰 + 总字节数上限（默认 10MB），避免内存无限增长。
type imageCache struct {
	mu       sync.Mutex
	maxBytes int64
	curBytes int64
	ll       *list.List               // 元素为 *cacheEntry（队首=最近使用）
	items    map[string]*list.Element // hash -> list element
}

type cacheEntry struct {
	key     string
	value   string
	bytes   int64
	expires time.Time
}

// newImageCache 创建图片描述缓存，maxBytes 为总占用上限（字节）。
func newImageCache(maxBytes int64) *imageCache {
	if maxBytes <= 0 {
		maxBytes = 10 << 20 // 默认 10MB
	}
	return &imageCache{
		maxBytes: maxBytes,
		ll:       list.New(),
		items:    make(map[string]*list.Element),
	}
}

// Get 按图片哈希取描述；命中且未过期返回描述，否则返回空。
func (c *imageCache) Get(hash string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	el, ok := c.items[hash]
	if !ok {
		return ""
	}
	entry := el.Value.(*cacheEntry)
	if time.Now().After(entry.expires) {
		// 过期：移除
		c.removeLocked(el)
		return ""
	}
	// LRU：移到队首
	c.ll.MoveToFront(el)
	return entry.value
}

// Set 缓存图片描述。若总占用超上限，从队尾淘汰最久未用项。
func (c *imageCache) Set(hash, desc string, ttl time.Duration) {
	if hash == "" || desc == "" {
		return
	}
	if ttl <= 0 {
		ttl = 24 * time.Hour // 默认 TTL 24h
	}
	c.mu.Lock()
	defer c.mu.Unlock()

	// 已存在：更新值并移到队首
	if el, ok := c.items[hash]; ok {
		entry := el.Value.(*cacheEntry)
		c.curBytes += int64(len(desc)) - int64(len(entry.value))
		entry.value = desc
		entry.bytes = int64(len(desc))
		entry.expires = time.Now().Add(ttl)
		c.ll.MoveToFront(el)
		c.evictLocked()
		return
	}

	entry := &cacheEntry{
		key:     hash,
		value:   desc,
		bytes:   int64(len(desc)),
		expires: time.Now().Add(ttl),
	}
	el := c.ll.PushFront(entry)
	c.items[hash] = el
	c.curBytes += entry.bytes
	c.evictLocked()
}

// Len 返回缓存条目数（测试用）。
func (c *imageCache) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ll.Len()
}

// CurBytes 返回当前占用字节数（测试用）。
func (c *imageCache) CurBytes() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.curBytes
}

// evictLocked 从队尾淘汰直到占用不超上限。
func (c *imageCache) evictLocked() {
	for c.curBytes > c.maxBytes && c.ll.Len() > 0 {
		back := c.ll.Back()
		if back == nil {
			return
		}
		c.removeLocked(back)
	}
}

// removeLocked 从链表与 map 移除条目并扣减字节。
func (c *imageCache) removeLocked(el *list.Element) {
	entry := el.Value.(*cacheEntry)
	c.ll.Remove(el)
	delete(c.items, entry.key)
	c.curBytes -= entry.bytes
}

// globalImageCache 全局图片描述缓存（bmssm 进程级）。
var globalImageCache = newImageCache(10 << 20)
