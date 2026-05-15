import { useRef, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { BarChart2, LogOut, RefreshCw, Settings, ShieldAlert, Tag as TagIcon, X } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { NodeListResponse, TagOut } from '../types'
import api from '../api/client'
import StatsCards from '../components/StatsCards'
import NodeTable from '../components/NodeTable'
import { copyToClipboard } from '../utils/clipboard'

type BulkAction = 'update_script' | 'install_scrot'

const BULK_ACTIONS: { id: BulkAction; label: string; cls: string; confirmMsg: (n: number) => string }[] = [
  {
    id: 'update_script',
    label: 'Cập nhật Script',
    cls: 'bg-indigo-600 hover:bg-indigo-700 disabled:bg-indigo-300',
    confirmMsg: n => `Gửi lệnh cập nhật script đến ${n} node?`,
  },
  {
    id: 'install_scrot',
    label: 'Cài scrot',
    cls: 'bg-orange-500 hover:bg-orange-600 disabled:bg-orange-300',
    confirmMsg: n => `Gửi lệnh cài scrot đến ${n} node?`,
  },
]

export default function Dashboard() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [statusFilter, setStatusFilter] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())

  // Tag filter state
  const [tagFilterIds, setTagFilterIds] = useState<number[]>([])
  const [tagMode, setTagMode] = useState<'or' | 'and'>('or')
  const [tagDropOpen, setTagDropOpen] = useState(false)
  const tagDropRef = useRef<HTMLDivElement>(null)

  // Bulk tag modal state
  const [bulkTagOpen, setBulkTagOpen] = useState(false)
  const [bulkAddIds, setBulkAddIds] = useState<Set<number>>(new Set())
  const [bulkRemoveIds, setBulkRemoveIds] = useState<Set<number>>(new Set())

  const { data: allTags = [] } = useQuery<TagOut[]>({
    queryKey: ['tags'],
    queryFn: () => api.get('/tags').then(r => r.data),
  })

  const params = new URLSearchParams()
  if (statusFilter) params.set('status_filter', statusFilter)
  if (search) params.set('search', search)
  if (tagFilterIds.length > 0) {
    params.set('tag_ids', tagFilterIds.join(','))
    params.set('tag_mode', tagMode)
  }

  const { data, isLoading, refetch, dataUpdatedAt, isFetching } = useQuery<NodeListResponse>({
    queryKey: ['nodes', statusFilter, search, tagFilterIds, tagMode],
    queryFn: () => api.get(`/dashboard/nodes?${params}`).then(r => r.data),
    refetchInterval: 30_000,
  })

  const bulkSend = useMutation({
    mutationFn: ({ action, node_ids }: { action: string; node_ids: string[] }) =>
      api.post('/dashboard/commands/bulk', { action, node_ids }).then(r => r.data),
    onSuccess: (result, vars) => {
      qc.invalidateQueries({ queryKey: ['commands'] })
      alert(`Đã gửi lệnh "${vars.action}" đến ${result.created} node${result.skipped ? ` (bỏ qua ${result.skipped})` : ''}.`)
      setSelectedIds(new Set())
    },
  })

  const bulkTagMutation = useMutation({
    mutationFn: ({ node_ids, add_tag_ids, remove_tag_ids }: { node_ids: string[]; add_tag_ids: number[]; remove_tag_ids: number[] }) =>
      api.post('/dashboard/nodes/bulk-tags', { node_ids, add_tag_ids, remove_tag_ids }).then(r => r.data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['nodes'] })
      setBulkTagOpen(false)
      setBulkAddIds(new Set())
      setBulkRemoveIds(new Set())
    },
  })

  const handleBulkTag = () => {
    const node_ids = [...selectedIds]
    const add_tag_ids = [...bulkAddIds]
    const remove_tag_ids = [...bulkRemoveIds]
    if (add_tag_ids.length === 0 && remove_tag_ids.length === 0) return
    bulkTagMutation.mutate({ node_ids, add_tag_ids, remove_tag_ids })
  }

  const handleTagClick = (tagId: number) => {
    setTagFilterIds(prev => prev.includes(tagId) ? prev : [...prev, tagId])
    setStatusFilter(null)
    setSearch('')
  }

  const handleBulkAction = (action: BulkAction) => {
    const ids = [...selectedIds]
    const def = BULK_ACTIONS.find(a => a.id === action)!
    if (!confirm(def.confirmMsg(ids.length))) return
    bulkSend.mutate({ action, node_ids: ids })
  }

  const handleCopySerials = () => {
    const selected = (data?.nodes ?? [])
      .filter(n => selectedIds.has(n.node_id))
      .sort((a, b) => a.node_id.localeCompare(b.node_id))
    if (selected.length === 0) { alert('Chưa chọn node nào.'); return }
    const serials = selected.map(n => n.serial ?? 'N/A')
    copyToClipboard(serials.join('\n'))
    alert(`Đã copy ${selected.length} serial vào clipboard.`)
  }

  const handleExportCsv = () => {
    const selected = (data?.nodes ?? [])
      .filter(n => selectedIds.has(n.node_id))
      .sort((a, b) => a.node_id.localeCompare(b.node_id))
    if (selected.length === 0) { alert('Chưa chọn node nào.'); return }

    const headers = ['Hostname', 'Account', 'Serial', 'Status', 'Proxy OK', 'Public IP', 'Proxy', 'Uptime %', 'Điểm hôm qua', 'Tổng điểm', 'Script Version', 'Last Seen']
    const rows = selected.map(n => [
      n.node_id,
      n.account ?? '',
      n.serial ?? '',
      n.aro_status ?? '',
      n.proxy_ok == null ? '' : n.proxy_ok ? 'OK' : 'Down',
      n.public_ip ?? '',
      n.proxy_host ? `${n.proxy_host}:${n.proxy_port}` : '',
      n.uptime_ratio != null ? (n.uptime_ratio * 100).toFixed(1) : '',
      n.reward_yesterday ?? '',
      n.total_score ?? '',
      n.script_version ?? '',
      n.last_seen ? new Date(n.last_seen + 'Z').toLocaleString('vi-VN') : '',
    ])

    const csv = [headers, ...rows]
      .map(row => row.map(v => `"${String(v).replace(/"/g, '""')}"`).join(','))
      .join('\r\n')

    const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `aro-nodes-${new Date().toISOString().slice(0, 10)}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  const selectAll = () => {
    const allIds = data?.nodes.map(n => n.node_id) ?? []
    setSelectedIds(new Set(allIds))
  }

  const logout = () => {
    localStorage.removeItem('token')
    navigate('/login')
  }

  const handleFilter = (f: string | null) => {
    setStatusFilter(f)
    setSearch('')
    setTagFilterIds([])
    setSelectedIds(new Set())
  }

  const handleSearch = (v: string) => {
    setSearch(v)
    setStatusFilter(null)
    setSelectedIds(new Set())
  }

  const removeTagFilter = (tagId: number) => {
    setTagFilterIds(prev => prev.filter(id => id !== tagId))
  }

  const selectedCount = selectedIds.size
  const visibleNodes = data?.nodes ?? []

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-screen-2xl mx-auto px-4 py-3 flex items-center justify-between">
          <div>
            <h1 className="text-lg font-bold text-gray-800">ARO Dashboard</h1>
            <p className="text-xs text-gray-400">
              {dataUpdatedAt
                ? `Cập nhật lúc ${new Date(dataUpdatedAt).toLocaleTimeString('vi-VN')} · tự refresh 30s`
                : 'Đang tải...'}
            </p>
          </div>
          <div className="flex items-center gap-1">
            <button
              onClick={() => navigate('/accounts')}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm text-gray-600 hover:text-gray-900 hover:bg-gray-100 rounded-lg transition-colors"
              title="Thống kê theo Account"
            >
              <BarChart2 size={15} />
              <span className="hidden sm:inline">Thống kê Account</span>
            </button>
            <button
              onClick={() => navigate('/errors')}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm text-gray-600 hover:text-gray-900 hover:bg-gray-100 rounded-lg transition-colors"
              title="Thống kê lỗi & Chất lượng"
            >
              <ShieldAlert size={15} />
              <span className="hidden sm:inline">Chất lượng Node</span>
            </button>
            <button
              onClick={() => navigate('/settings')}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm text-gray-600 hover:text-gray-900 hover:bg-gray-100 rounded-lg transition-colors"
              title="Cài đặt"
            >
              <Settings size={15} />
              <span className="hidden sm:inline">Cài đặt</span>
            </button>
            <button
              onClick={() => refetch()}
              disabled={isFetching}
              className="p-2 text-gray-500 hover:text-gray-800 disabled:opacity-40 transition-colors"
              title="Refresh"
            >
              <RefreshCw size={16} className={isFetching ? 'animate-spin' : ''} />
            </button>
            <button
              onClick={logout}
              className="p-2 text-gray-500 hover:text-gray-800 transition-colors"
              title="Đăng xuất"
            >
              <LogOut size={16} />
            </button>
          </div>
        </div>
      </header>

      <main className="max-w-screen-2xl mx-auto px-4 py-5 space-y-5">
        {data && (
          <StatsCards stats={data} activeFilter={statusFilter} onFilter={handleFilter} />
        )}

        <div className="flex items-center gap-3 flex-wrap">
          <input
            type="text"
            placeholder="Tìm theo hostname hoặc account..."
            value={search}
            onChange={e => handleSearch(e.target.value)}
            className="flex-1 min-w-[200px] border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
          />

          {/* Tag filter dropdown */}
          <div ref={tagDropRef} className="relative">
            <button
              onClick={() => setTagDropOpen(o => !o)}
              className={`flex items-center gap-1.5 px-3 py-2 text-sm rounded-lg border transition-colors ${tagFilterIds.length > 0 ? 'bg-blue-50 border-blue-300 text-blue-700' : 'bg-white border-gray-300 text-gray-600 hover:border-gray-400'}`}
            >
              <TagIcon size={14} />
              Tag{tagFilterIds.length > 0 ? ` (${tagFilterIds.length})` : ''}
            </button>
            {tagDropOpen && (
              <div className="absolute left-0 top-11 z-20 w-56 bg-white border border-gray-200 rounded-xl shadow-lg py-1">
                {allTags.length === 0 ? (
                  <p className="text-xs text-gray-400 px-3 py-2 italic">Chưa có tag nào.</p>
                ) : (
                  <>
                    {allTags.map(tag => {
                      const active = tagFilterIds.includes(tag.id)
                      return (
                        <button
                          key={tag.id}
                          onClick={() => {
                            setTagFilterIds(prev =>
                              active ? prev.filter(id => id !== tag.id) : [...prev, tag.id]
                            )
                            setStatusFilter(null)
                            setSearch('')
                          }}
                          className="w-full flex items-center gap-2 px-3 py-1.5 hover:bg-gray-50 text-left"
                        >
                          <span
                            className="w-3 h-3 rounded-full flex-shrink-0 border-2"
                            style={{ backgroundColor: active ? tag.color : 'transparent', borderColor: tag.color }}
                          />
                          <span className="text-sm text-gray-700 flex-1">{tag.name}</span>
                          <span className="text-xs text-gray-400">{tag.node_count}</span>
                        </button>
                      )
                    })}
                    {tagFilterIds.length >= 2 && (
                      <div className="border-t border-gray-100 px-3 py-2 flex items-center gap-2">
                        <span className="text-xs text-gray-500">Chế độ lọc:</span>
                        <button
                          onClick={() => setTagMode('or')}
                          className={`text-xs px-2 py-0.5 rounded-full border transition-colors ${tagMode === 'or' ? 'bg-blue-600 text-white border-blue-600' : 'text-gray-600 border-gray-300 hover:border-blue-400'}`}
                        >
                          OR
                        </button>
                        <button
                          onClick={() => setTagMode('and')}
                          className={`text-xs px-2 py-0.5 rounded-full border transition-colors ${tagMode === 'and' ? 'bg-blue-600 text-white border-blue-600' : 'text-gray-600 border-gray-300 hover:border-blue-400'}`}
                        >
                          AND
                        </button>
                      </div>
                    )}
                    {tagFilterIds.length > 0 && (
                      <div className="border-t border-gray-100 px-3 py-1.5">
                        <button
                          onClick={() => setTagFilterIds([])}
                          className="text-xs text-red-500 hover:text-red-700"
                        >
                          Xoá bộ lọc tag
                        </button>
                      </div>
                    )}
                  </>
                )}
              </div>
            )}
          </div>

          {statusFilter && (
            <button
              onClick={() => setStatusFilter(null)}
              className="flex items-center gap-1 px-3 py-2 text-sm bg-blue-50 text-blue-700 border border-blue-200 rounded-lg hover:bg-blue-100 transition-colors"
            >
              {statusFilter} <X size={13} />
            </button>
          )}
          {tagFilterIds.map(tid => {
            const tag = allTags.find(t => t.id === tid)
            if (!tag) return null
            return (
              <button
                key={tid}
                onClick={() => removeTagFilter(tid)}
                className="flex items-center gap-1 px-3 py-2 text-xs font-medium text-white rounded-lg"
                style={{ backgroundColor: tag.color }}
              >
                {tag.name} <X size={11} />
              </button>
            )
          })}

          <span className="text-sm text-gray-400 whitespace-nowrap">
            {visibleNodes.length} / {data?.total ?? 0} nodes
          </span>
        </div>

        {/* Bulk action bar */}
        {selectedCount > 0 && (
          <div className="flex items-center gap-3 flex-wrap bg-white border border-blue-200 rounded-xl px-4 py-3 shadow-sm">
            <span className="text-sm font-medium text-blue-700">
              {selectedCount} node đã chọn
            </span>
            <button
              onClick={() => setSelectedIds(new Set())}
              className="text-xs text-gray-400 hover:text-gray-600 underline"
            >
              Bỏ chọn
            </button>
            {selectedCount < visibleNodes.length && (
              <button
                onClick={selectAll}
                className="text-xs text-blue-500 hover:text-blue-700 underline"
              >
                Chọn tất cả {visibleNodes.length} node
              </button>
            )}
            <div className="flex-1" />
            <button
              onClick={handleCopySerials}
              className="px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 border border-gray-300 rounded-lg hover:bg-gray-200 transition-colors"
            >
              Copy Serials ({selectedCount})
            </button>
            <button
              onClick={handleExportCsv}
              className="px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 border border-gray-300 rounded-lg hover:bg-gray-200 transition-colors"
            >
              Xuất CSV ({selectedCount})
            </button>
            <button
              onClick={() => { setBulkTagOpen(true); setBulkAddIds(new Set()); setBulkRemoveIds(new Set()) }}
              className="flex items-center gap-1.5 px-4 py-2 text-sm font-medium text-teal-700 bg-teal-50 border border-teal-300 rounded-lg hover:bg-teal-100 transition-colors"
            >
              <TagIcon size={14} /> Gắn/Gỡ Tag ({selectedCount})
            </button>
            {BULK_ACTIONS.map(action => (
              <button
                key={action.id}
                onClick={() => handleBulkAction(action.id)}
                disabled={bulkSend.isPending}
                className={`px-4 py-2 text-sm font-medium text-white rounded-lg transition-colors disabled:opacity-50 ${action.cls}`}
              >
                {bulkSend.isPending && bulkSend.variables?.action === action.id
                  ? 'Đang gửi...'
                  : `${action.label} (${selectedCount})`}
              </button>
            ))}
          </div>
        )}

        {/* Bulk tag modal */}
        {bulkTagOpen && (
          <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
            <div className="bg-white rounded-xl shadow-xl p-6 w-full max-w-sm mx-4">
              <h3 className="text-base font-semibold text-gray-800 mb-1">Gắn/Gỡ Tag</h3>
              <p className="text-sm text-gray-500 mb-4">Áp dụng cho {selectedCount} node đã chọn.</p>
              {allTags.length === 0 ? (
                <p className="text-sm text-gray-400 italic mb-4">Chưa có tag nào. Hãy tạo tag trong Cài đặt.</p>
              ) : (
                <div className="space-y-1 mb-4 max-h-60 overflow-y-auto">
                  {allTags.map(tag => {
                    const adding = bulkAddIds.has(tag.id)
                    const removing = bulkRemoveIds.has(tag.id)
                    return (
                      <div key={tag.id} className="flex items-center gap-2 py-1 px-1 rounded-lg hover:bg-gray-50">
                        <span className="w-3 h-3 rounded-full flex-shrink-0" style={{ backgroundColor: tag.color }} />
                        <span className="flex-1 text-sm text-gray-700">{tag.name}</span>
                        <button
                          onClick={() => {
                            setBulkAddIds(prev => { const n = new Set(prev); adding ? n.delete(tag.id) : n.add(tag.id); return n })
                            setBulkRemoveIds(prev => { const n = new Set(prev); n.delete(tag.id); return n })
                          }}
                          className={`px-2 py-0.5 text-xs rounded-full border transition-colors ${adding ? 'bg-green-500 text-white border-green-500' : 'text-green-600 border-green-400 hover:bg-green-50'}`}
                        >
                          + Gắn
                        </button>
                        <button
                          onClick={() => {
                            setBulkRemoveIds(prev => { const n = new Set(prev); removing ? n.delete(tag.id) : n.add(tag.id); return n })
                            setBulkAddIds(prev => { const n = new Set(prev); n.delete(tag.id); return n })
                          }}
                          className={`px-2 py-0.5 text-xs rounded-full border transition-colors ${removing ? 'bg-red-500 text-white border-red-500' : 'text-red-500 border-red-400 hover:bg-red-50'}`}
                        >
                          − Gỡ
                        </button>
                      </div>
                    )
                  })}
                </div>
              )}
              <div className="flex gap-3 justify-end">
                <button
                  onClick={() => setBulkTagOpen(false)}
                  className="px-4 py-2 text-sm text-gray-700 bg-gray-100 rounded-lg hover:bg-gray-200"
                >
                  Huỷ
                </button>
                <button
                  onClick={handleBulkTag}
                  disabled={bulkTagMutation.isPending || (bulkAddIds.size === 0 && bulkRemoveIds.size === 0)}
                  className="px-4 py-2 text-sm text-white bg-teal-600 rounded-lg hover:bg-teal-700 disabled:opacity-50"
                >
                  {bulkTagMutation.isPending ? 'Đang áp dụng...' : 'Áp dụng'}
                </button>
              </div>
            </div>
          </div>
        )}

        {isLoading ? (
          <div className="text-center py-20 text-gray-400">Đang tải danh sách node...</div>
        ) : (
          <NodeTable
            nodes={visibleNodes}
            selectedIds={selectedIds}
            onSelectionChange={setSelectedIds}
            onTagClick={handleTagClick}
          />
        )}
      </main>
    </div>
  )
}
