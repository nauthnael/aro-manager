import { useState, useEffect, useRef, useCallback } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { BarChart2, LogOut, RefreshCw, Settings, ShieldAlert, RotateCcw, Globe, Tag as TagIcon, X } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { type SortingState } from '@tanstack/react-table'
import { NodeListResponse, TagOut } from '../types'
import api from '../api/client'
import StatsCards from '../components/StatsCards'
import NodeTable from '../components/NodeTable'
import BulkProxyModal from '../components/BulkProxyModal'
import { copyToClipboard } from '../utils/clipboard'

const PAGE_SIZE_OPTIONS = [10, 20, 50, 100, 200, 500]

type BulkAction = 'update_script' | 'install_scrot' | 'restart_aro' | 'restart_watchdog' | 'reboot_vps' | 'proxy_test'

const BULK_ACTIONS: { id: BulkAction; label: string; cls: string; confirmMsg: (n: number) => string }[] = [
  {
    id: 'update_script',
    label: 'Cập nhật Script',
    cls: 'bg-indigo-600 hover:bg-indigo-700 disabled:bg-indigo-300',
    confirmMsg: n => `Gửi lệnh cập nhật script đến ${n} node?`,
  },
  {
    id: 'restart_aro',
    label: 'Restart ARO',
    cls: 'bg-green-600 hover:bg-green-700 disabled:bg-green-300',
    confirmMsg: n => `Gửi lệnh restart ARO đến ${n} node?`,
  },
  {
    id: 'restart_watchdog',
    label: 'Restart Watchdog',
    cls: 'bg-teal-600 hover:bg-teal-700 disabled:bg-teal-300',
    confirmMsg: n => `Gửi lệnh restart Watchdog đến ${n} node?`,
  },
  {
    id: 'proxy_test',
    label: 'Test Proxy',
    cls: 'bg-cyan-600 hover:bg-cyan-700 disabled:bg-cyan-300',
    confirmMsg: n => `Gửi lệnh test proxy đến ${n} node?`,
  },
  {
    id: 'install_scrot',
    label: 'Cài scrot',
    cls: 'bg-orange-500 hover:bg-orange-600 disabled:bg-orange-300',
    confirmMsg: n => `Gửi lệnh cài scrot đến ${n} node?`,
  },
  {
    id: 'reboot_vps',
    label: 'Reboot VPS',
    cls: 'bg-red-700 hover:bg-red-800 disabled:bg-red-400',
    confirmMsg: n => `Reboot VPS của ${n} node? Hành động này sẽ khởi động lại máy chủ!`,
  },
]

export default function Dashboard() {
  useEffect(() => { document.title = '💲 ARO Dashboard' }, [])
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [statusFilter, setStatusFilter] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [debouncedSearch, setDebouncedSearch] = useState('')
  const searchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(50)
  const [sorting, setSorting] = useState<SortingState>([{ id: 'node_id', desc: false }])

  // Tag filter state
  const [tagFilterIds, setTagFilterIds] = useState<number[]>([])
  const [tagMode, setTagMode] = useState<'or' | 'and'>('or')
  const [tagDropOpen, setTagDropOpen] = useState(false)
  const tagDropRef = useRef<HTMLDivElement>(null)

  // Bulk tag modal state
  const [bulkTagOpen, setBulkTagOpen] = useState(false)
  const [bulkAddIds, setBulkAddIds] = useState<Set<number>>(new Set())
  const [bulkRemoveIds, setBulkRemoveIds] = useState<Set<number>>(new Set())

  // Bulk proxy modal state
  const [bulkProxyOpen, setBulkProxyOpen] = useState(false)

  const bulkBarRef = useRef<HTMLDivElement>(null)
  const [bulkBarHeight, setBulkBarHeight] = useState(0)
  useEffect(() => {
    const el = bulkBarRef.current
    if (!el) { setBulkBarHeight(0); return }
    setBulkBarHeight(el.getBoundingClientRect().height)
    const ro = new ResizeObserver(() => setBulkBarHeight(el.getBoundingClientRect().height))
    ro.observe(el)
    return () => ro.disconnect()
  }, [selectedIds])

const { data: allTags = [] } = useQuery<TagOut[]>({
    queryKey: ['tags'],
    queryFn: () => api.get('/tags').then(r => r.data),
  })

  const sortBy = sorting[0]?.id ?? 'node_id'
  const sortDir = sorting[0]?.desc ? 'desc' : 'asc'

  const params = new URLSearchParams()
  if (statusFilter === 'noPointsYesterday') params.set('no_points_yesterday', 'true')
  else if (statusFilter === 'noPointsAvg') params.set('no_points_avg', 'true')
  else if (statusFilter === 'noPoints2Days') params.set('no_points_2days', 'true')
  else if (statusFilter) params.set('status_filter', statusFilter)
  if (debouncedSearch) params.set('search', debouncedSearch)
  params.set('page', String(page))
  params.set('page_size', String(pageSize))
  params.set('sort_by', sortBy)
  params.set('sort_dir', sortDir)
  if (tagFilterIds.length > 0) {
    params.set('tag_ids', tagFilterIds.join(','))
    params.set('tag_mode', tagMode)
  }

  const { data, isLoading, refetch, dataUpdatedAt, isFetching } = useQuery<NodeListResponse>({
    queryKey: ['nodes', statusFilter, debouncedSearch, page, pageSize, sortBy, sortDir, tagFilterIds, tagMode],
    queryFn: () => api.get(`/dashboard/nodes?${params}`).then(r => r.data),
    refetchInterval: 30_000,
    staleTime: 25_000,
  })

  const handleSortingChange = useCallback((s: SortingState) => {
    setSorting(s)
    setPage(1)
  }, [])

  const handlePageSize = (size: number) => {
    setPageSize(size)
    setPage(1)
    setSelectedIds(new Set())
  }

  const bulkSend = useMutation({
    mutationFn: ({ action, node_ids }: { action: string; node_ids: string[] }) =>
      api.post('/dashboard/commands/bulk', { action, node_ids }).then(r => r.data),
    onSuccess: (result, vars) => {
      qc.invalidateQueries({ queryKey: ['commands'] })
      alert(`Đã gửi lệnh "${vars.action}" đến ${result.created} node${result.skipped ? ` (bỏ qua ${result.skipped})` : ''}.`)
      setSelectedIds(new Set())
    },
  })

  const bulkRenew = useMutation({
    mutationFn: (node_ids: string[]) =>
      api.post('/renew/bulk', { node_ids }).then(r => r.data),
    onSuccess: (result) => {
      qc.invalidateQueries({ queryKey: ['nodes'] })
      alert(`Đã kích hoạt renew cho ${result.triggered} node${result.skipped ? ` (bỏ qua ${result.skipped})` : ''}.`)
      setSelectedIds(new Set())
    },
  })

  const bulkSetProxy = useMutation({
    mutationFn: (assignments: { node_id: string; proxy: string }[]) =>
      api.post('/dashboard/nodes/bulk-set-proxy', { assignments }).then(r => r.data),
    onSuccess: (result) => {
      qc.invalidateQueries({ queryKey: ['commands'] })
      alert(`Đã gửi lệnh đổi proxy đến ${result.created} node.`)
      setBulkProxyOpen(false)
      setSelectedIds(new Set())
    },
    onError: (err: any) => {
      alert(`Lỗi: ${err?.response?.data?.detail ?? 'Không thể đổi proxy'}`)
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

  const handleTagClick = useCallback((tagId: number) => {
    setTagFilterIds(prev => prev.includes(tagId) ? prev : [...prev, tagId])
    setStatusFilter(null)
    setSearch('')
    setDebouncedSearch('')
  }, [])

  const removeTagFilter = useCallback((tagId: number) => {
    setTagFilterIds(prev => prev.filter(id => id !== tagId))
  }, [])

  const handleBulkAction = (action: BulkAction) => {
    const ids = [...selectedIds]
    const def = BULK_ACTIONS.find(a => a.id === action)!
    if (!confirm(def.confirmMsg(ids.length))) return
    bulkSend.mutate({ action, node_ids: ids })
  }

  const handleBulkRenew = () => {
    const ids = [...selectedIds]
    if (!confirm(`Renew ${ids.length} node đã chọn? Các node đang trong cooldown sẽ bị bỏ qua.`)) return
    bulkRenew.mutate(ids)
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

  const handleFilter = useCallback((f: string | null) => {
    if (f === 'renew0pts') {
      navigate('/renew?tab=stats')
      return
    }
    setStatusFilter(f)
    setSearch('')
    setDebouncedSearch('')
    setTagFilterIds([])
    setSelectedIds(new Set())
    setPage(1)
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }, [navigate])

  const handleSearch = (v: string) => {
    setSearch(v)
    if (searchTimerRef.current) clearTimeout(searchTimerRef.current)
    searchTimerRef.current = setTimeout(() => {
      setDebouncedSearch(v)
      setStatusFilter(null)
      setSelectedIds(new Set())
      setPage(1)
      window.scrollTo({ top: 0, behavior: 'smooth' })
    }, 400)
  }

  const selectedCount = selectedIds.size
  const visibleNodes = data?.nodes ?? []

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-[1880px] mx-auto px-4 py-3 flex items-center justify-between">
          <div>
            <h1 className="text-lg font-bold text-gray-800">💲 ARO Dashboard</h1>
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
              onClick={() => navigate('/renew')}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm text-orange-600 hover:text-orange-800 hover:bg-orange-50 rounded-lg transition-colors"
              title="Renew Node"
            >
              <RotateCcw size={15} />
              <span className="hidden sm:inline">Renew Node</span>
            </button>
            <button
              onClick={() => navigate('/ip-manager')}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm text-blue-600 hover:text-blue-800 hover:bg-blue-50 rounded-lg transition-colors"
              title="Quản lý IP Nodes"
            >
              <Globe size={15} />
              <span className="hidden sm:inline">IP Manager</span>
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

      <main className="max-w-[1880px] mx-auto px-4 py-5 space-y-5">
        {isLoading ? (
          <div className="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-8 gap-3">
            {Array.from({ length: 8 }).map((_, i) => (
              <div key={i} className="bg-white rounded-lg shadow px-3 py-3 border-l-4 border-gray-200 animate-pulse">
                <div className="h-2 bg-gray-200 rounded w-16 mb-3" />
                <div className="h-6 bg-gray-200 rounded w-10" />
              </div>
            ))}
          </div>
        ) : data ? (
          <StatsCards stats={data} activeFilter={statusFilter} onFilter={handleFilter} />
        ) : null}

        <div className="flex items-center gap-3 flex-wrap">
          <input
            type="text"
            placeholder="Tìm theo hostname, account hoặc serial..."
            value={search}
            onChange={e => handleSearch(e.target.value)}
            className="flex-1 min-w-[200px] border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
          />
          {statusFilter && (
            <button
              onClick={() => setStatusFilter(null)}
              className="px-3 py-2 text-sm bg-blue-50 text-blue-700 border border-blue-200 rounded-lg hover:bg-blue-100 transition-colors"
            >
              Filter: {statusFilter} ✕
            </button>
          )}
          {/* Tag filter dropdown */}
          <div ref={tagDropRef} className="relative">
            <button
              onClick={() => setTagDropOpen(o => !o)}
              className={`flex items-center gap-1.5 px-3 py-2 text-sm rounded-lg border transition-colors ${
                tagFilterIds.length > 0
                  ? 'bg-teal-50 border-teal-300 text-teal-700'
                  : 'border-gray-300 text-gray-600 hover:border-gray-400'
              }`}
            >
              <TagIcon size={14} />
              Tags
              {tagFilterIds.length > 0 && (
                <span className="bg-teal-500 text-white text-xs px-1.5 py-0.5 rounded-full font-bold">{tagFilterIds.length}</span>
              )}
            </button>
            {tagDropOpen && (
              <div className="absolute left-0 top-10 z-20 w-56 bg-white border border-gray-200 rounded-xl shadow-lg py-1">
                {allTags.length === 0 ? (
                  <p className="text-xs text-gray-400 px-3 py-2 italic">Chưa có tag nào.</p>
                ) : (
                  allTags.map(tag => {
                    const active = tagFilterIds.includes(tag.id)
                    return (
                      <button
                        key={tag.id}
                        onClick={() => {
                          setTagFilterIds(prev =>
                            active ? prev.filter(id => id !== tag.id) : [...prev, tag.id]
                          )
                          setPage(1)
                        }}
                        className="w-full flex items-center gap-2 px-3 py-1.5 hover:bg-gray-50 text-left"
                      >
                        <span className="w-3 h-3 rounded-full flex-shrink-0 border-2"
                          style={{ backgroundColor: active ? tag.color : 'transparent', borderColor: tag.color }} />
                        <span className="text-sm text-gray-700 flex-1">{tag.name}</span>
                        <span className="text-xs text-gray-400">{tag.node_count}</span>
                      </button>
                    )
                  })
                )}
                {tagFilterIds.length >= 2 && (
                  <div className="border-t border-gray-100 mt-1 pt-1 px-3 py-1.5 flex items-center gap-2">
                    <span className="text-xs text-gray-500">Chế độ:</span>
                    <button
                      onClick={() => setTagMode('or')}
                      className={`text-xs px-2 py-0.5 rounded-full border transition-colors ${tagMode === 'or' ? 'bg-teal-500 text-white border-teal-500' : 'text-gray-500 border-gray-300 hover:border-gray-400'}`}
                    >OR</button>
                    <button
                      onClick={() => setTagMode('and')}
                      className={`text-xs px-2 py-0.5 rounded-full border transition-colors ${tagMode === 'and' ? 'bg-teal-500 text-white border-teal-500' : 'text-gray-500 border-gray-300 hover:border-gray-400'}`}
                    >AND</button>
                  </div>
                )}
              </div>
            )}
          </div>
          {/* Active tag chips */}
          {tagFilterIds.map(tagId => {
            const tag = allTags.find(t => t.id === tagId)
            if (!tag) return null
            return (
              <span key={tagId}
                className="inline-flex items-center gap-1 px-2 py-1 rounded-full text-xs font-medium text-white"
                style={{ backgroundColor: tag.color }}>
                {tag.name}
                <button onClick={() => removeTagFilter(tagId)} className="opacity-80 hover:opacity-100 ml-0.5">
                  <X size={11} />
                </button>
              </span>
            )
          })}
          <span className="text-sm text-gray-400 whitespace-nowrap">
            {data?.total_filtered ?? 0} / {data?.total ?? 0} nodes
          </span>
        </div>

        {/* Pagination + Page size */}
        {data && (
          <div className="flex items-center gap-3 justify-between flex-wrap bg-white border border-gray-200 rounded-xl px-4 py-2.5 shadow-sm">
            {/* Page size selector */}
            <div className="flex items-center gap-2 text-sm text-gray-600">
              <span>Hiển thị</span>
              <div className="flex gap-1">
                {PAGE_SIZE_OPTIONS.map(size => (
                  <button
                    key={size}
                    onClick={() => handlePageSize(size)}
                    className={`px-2.5 py-1 rounded text-xs font-medium transition-colors ${
                      pageSize === size
                        ? 'bg-blue-600 text-white'
                        : 'border border-gray-300 text-gray-600 hover:bg-gray-50'
                    }`}
                  >
                    {size}
                  </button>
                ))}
              </div>
              <span className="text-gray-400">/ trang</span>
            </div>

            {/* Page info + navigation */}
            <div className="flex items-center gap-2">
              <span className="text-sm text-gray-500 whitespace-nowrap">
                Trang <span className="font-medium text-gray-700">{data.page}</span> / {data.total_pages}
                <span className="text-gray-400 ml-2">({data.total_filtered.toLocaleString()} nodes)</span>
              </span>
              <div className="flex items-center gap-1">
                <button
                  onClick={() => setPage(1)}
                  disabled={page <= 1}
                  className="px-2 py-1.5 text-sm border border-gray-300 rounded-lg disabled:opacity-40 hover:bg-gray-50 transition-colors"
                  title="Trang đầu"
                >«</button>
                <button
                  onClick={() => setPage(p => Math.max(1, p - 1))}
                  disabled={page <= 1}
                  className="px-3 py-1.5 text-sm border border-gray-300 rounded-lg disabled:opacity-40 hover:bg-gray-50 transition-colors"
                >← Trước</button>
                <button
                  onClick={() => setPage(p => Math.min(data.total_pages, p + 1))}
                  disabled={page >= data.total_pages}
                  className="px-3 py-1.5 text-sm border border-gray-300 rounded-lg disabled:opacity-40 hover:bg-gray-50 transition-colors"
                >Tiếp →</button>
                <button
                  onClick={() => setPage(data.total_pages)}
                  disabled={page >= data.total_pages}
                  className="px-2 py-1.5 text-sm border border-gray-300 rounded-lg disabled:opacity-40 hover:bg-gray-50 transition-colors"
                  title="Trang cuối"
                >»</button>
              </div>
            </div>
          </div>
        )}

        {/* Bulk action bar */}
        {selectedCount > 0 && (
          <div ref={bulkBarRef} className="flex items-center gap-3 flex-wrap bg-white border border-blue-200 rounded-xl px-4 py-3 shadow-sm sticky top-14 z-20">
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
            <button
              onClick={handleBulkRenew}
              disabled={bulkRenew.isPending}
              className="px-4 py-2 text-sm font-medium text-white bg-orange-500 hover:bg-orange-600 disabled:bg-orange-300 rounded-lg transition-colors disabled:opacity-50"
            >
              {bulkRenew.isPending ? 'Đang renew...' : `Bulk Renew (${selectedCount})`}
            </button>
            <button
              onClick={() => setBulkProxyOpen(true)}
              className="px-4 py-2 text-sm font-medium text-white bg-violet-600 hover:bg-violet-700 rounded-lg transition-colors"
            >
              Đổi Proxy ({selectedCount})
            </button>
          </div>
        )}

        {isLoading ? (
          <div className="text-center py-20 text-gray-400">Đang tải danh sách node...</div>
        ) : (
          <NodeTable
            nodes={visibleNodes}
            selectedIds={selectedIds}
            onSelectionChange={setSelectedIds}
            sorting={sorting}
            onSortingChange={handleSortingChange}
            onTagClick={handleTagClick}
            page={page}
            pageSize={pageSize}
            stickyTop={56 + bulkBarHeight}
          />
        )}

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
                        >+ Gắn</button>
                        <button
                          onClick={() => {
                            setBulkRemoveIds(prev => { const n = new Set(prev); removing ? n.delete(tag.id) : n.add(tag.id); return n })
                            setBulkAddIds(prev => { const n = new Set(prev); n.delete(tag.id); return n })
                          }}
                          className={`px-2 py-0.5 text-xs rounded-full border transition-colors ${removing ? 'bg-red-500 text-white border-red-500' : 'text-red-500 border-red-400 hover:bg-red-50'}`}
                        >− Gỡ</button>
                      </div>
                    )
                  })}
                </div>
              )}
              <div className="flex gap-3 justify-end">
                <button onClick={() => setBulkTagOpen(false)} className="px-4 py-2 text-sm text-gray-700 bg-gray-100 rounded-lg hover:bg-gray-200">Huỷ</button>
                <button onClick={handleBulkTag}
                  disabled={bulkTagMutation.isPending || (bulkAddIds.size === 0 && bulkRemoveIds.size === 0)}
                  className="px-4 py-2 text-sm text-white bg-teal-600 rounded-lg hover:bg-teal-700 disabled:opacity-50">
                  {bulkTagMutation.isPending ? 'Đang áp dụng...' : 'Áp dụng'}
                </button>
              </div>
            </div>
          </div>
        )}
      </main>

      {bulkProxyOpen && (
        <BulkProxyModal
          nodes={visibleNodes.filter(n => selectedIds.has(n.node_id))}
          onClose={() => setBulkProxyOpen(false)}
          onSubmit={assignments => bulkSetProxy.mutate(assignments)}
          isPending={bulkSetProxy.isPending}
        />
      )}
    </div>
  )
}
