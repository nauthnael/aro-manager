import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { BarChart2, LogOut, RefreshCw, Settings, ShieldAlert } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { NodeListResponse } from '../types'
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
  const [noPointsYesterday, setNoPointsYesterday] = useState(false)
  const [noPointsAvg, setNoPointsAvg] = useState(false)
  const [excludeNewNodes, setExcludeNewNodes] = useState(false)

  const params = new URLSearchParams()
  if (statusFilter) params.set('status_filter', statusFilter)
  if (search) params.set('search', search)
  if (noPointsYesterday) params.set('no_points_yesterday', 'true')
  if (noPointsAvg)       params.set('no_points_avg', 'true')
  if (excludeNewNodes)   params.set('exclude_new_nodes', 'true')

  const { data, isLoading, refetch, dataUpdatedAt, isFetching } = useQuery<NodeListResponse>({
    queryKey: ['nodes', statusFilter, search, noPointsYesterday, noPointsAvg, excludeNewNodes],
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
    setNoPointsYesterday(false)
    setNoPointsAvg(false)
    setExcludeNewNodes(false)
    setSelectedIds(new Set())
  }

  const handleSearch = (v: string) => {
    setSearch(v)
    setStatusFilter(null)
    setNoPointsYesterday(false)
    setNoPointsAvg(false)
    setSelectedIds(new Set())
  }

  const selectedCount = selectedIds.size
  const visibleNodes = data?.nodes ?? []

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-screen-2xl mx-auto px-4 py-3 flex items-center justify-between">
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
          {statusFilter && (
            <button
              onClick={() => setStatusFilter(null)}
              className="px-3 py-2 text-sm bg-blue-50 text-blue-700 border border-blue-200 rounded-lg hover:bg-blue-100 transition-colors"
            >
              Filter: {statusFilter} ✕
            </button>
          )}
          <span className="text-sm text-gray-400 whitespace-nowrap">
            {visibleNodes.length} / {data?.total ?? 0} nodes
          </span>
        </div>

        {/* Point filters */}
        <div className="flex items-center gap-4 flex-wrap text-sm text-gray-600">
          <label className={`flex items-center gap-2 cursor-pointer select-none px-3 py-1.5 rounded-lg border transition-colors
            ${noPointsYesterday ? 'bg-orange-50 border-orange-300 text-orange-700' : 'border-gray-200 hover:border-gray-300'}`}>
            <input
              type="checkbox"
              checked={noPointsYesterday}
              onChange={e => {
                setNoPointsYesterday(e.target.checked)
                setStatusFilter(null)
                setSearch('')
                setSelectedIds(new Set())
              }}
              className="accent-orange-500"
            />
            Không điểm hôm qua
          </label>
          <label className={`flex items-center gap-2 cursor-pointer select-none px-3 py-1.5 rounded-lg border transition-colors
            ${noPointsAvg ? 'bg-red-50 border-red-300 text-red-700' : 'border-gray-200 hover:border-gray-300'}`}>
            <input
              type="checkbox"
              checked={noPointsAvg}
              onChange={e => {
                setNoPointsAvg(e.target.checked)
                setStatusFilter(null)
                setSearch('')
                setSelectedIds(new Set())
              }}
              className="accent-red-500"
            />
            Trung bình 0 điểm
          </label>
          {(noPointsYesterday || noPointsAvg) && (
            <label className="flex items-center gap-2 cursor-pointer select-none text-gray-500 border-l pl-4 ml-1">
              <input
                type="checkbox"
                checked={excludeNewNodes}
                onChange={e => setExcludeNewNodes(e.target.checked)}
                className="accent-gray-500"
              />
              Chỉ node hoạt động trên 1 ngày
            </label>
          )}
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

        {isLoading ? (
          <div className="text-center py-20 text-gray-400">Đang tải danh sách node...</div>
        ) : (
          <NodeTable
            nodes={visibleNodes}
            selectedIds={selectedIds}
            onSelectionChange={setSelectedIds}
          />
        )}
      </main>
    </div>
  )
}
