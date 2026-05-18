import { useState, useEffect } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { ArrowLeft, RefreshCw, RotateCcw, History, AlertTriangle, Clock, Download, BarChart2, ChevronUp, ChevronDown } from 'lucide-react'
import { formatDistanceToNow, parseISO } from 'date-fns'
import { vi } from 'date-fns/locale'
import api from '../api/client'
import { RenewCandidatesResponse, RenewHistoryResponse, RenewCandidate, RenewLog, RenewStatsResponse, RenewStatsNode } from '../types'
import { useGoBack } from '../utils/navigation'

type Tab = 'candidates' | 'history' | 'stats'

function StatusBadge({ status }: { status: string | null }) {
  if (!status) return <span className="text-gray-400">—</span>
  const map: Record<string, string> = {
    Online:        'bg-green-100 text-green-800',
    Offline:       'bg-red-100 text-red-800',
    NoInternet:    'bg-yellow-100 text-yellow-800',
    Unbound:       'bg-purple-100 text-purple-800',
    proxy_expired: 'bg-orange-100 text-orange-800',
  }
  return (
    <span className={`px-1.5 py-0.5 rounded text-xs font-medium ${map[status] ?? 'bg-gray-100 text-gray-600'}`}>
      {status}
    </span>
  )
}

function RenewStatusBadge({ status }: { status: string }) {
  const map: Record<string, string> = {
    pending: 'bg-yellow-100 text-yellow-800',
    completed: 'bg-green-100 text-green-800',
    failed: 'bg-red-100 text-red-800',
  }
  const labels: Record<string, string> = {
    pending: 'Đang xử lý',
    completed: 'Thành công',
    failed: 'Thất bại',
  }
  return (
    <span className={`px-1.5 py-0.5 rounded text-xs font-medium ${map[status] ?? 'bg-gray-100 text-gray-600'}`}>
      {labels[status] ?? status}
    </span>
  )
}

function formatTime(iso: string | null) {
  if (!iso) return '—'
  try {
    return formatDistanceToNow(parseISO(iso + 'Z'), { addSuffix: true, locale: vi })
  } catch {
    return iso
  }
}

function SortIcon({ col, sortBy, sortDir }: { col: string; sortBy: string; sortDir: string }) {
  if (sortBy !== col) return <span className="text-gray-300 ml-0.5">↕</span>
  return sortDir === 'desc'
    ? <ChevronDown size={12} className="inline ml-0.5 text-orange-500" />
    : <ChevronUp size={12} className="inline ml-0.5 text-orange-500" />
}

function ActionMenu({ node, onAction }: { node: RenewStatsNode; onAction: (nodeId: string, action: string) => void }) {
  const [open, setOpen] = useState(false)
  const actions = [
    { key: 'restart_aro',      label: 'Restart ARO',       color: 'text-blue-600' },
    { key: 'restart_watchdog', label: 'Restart Watchdog',  color: 'text-blue-600' },
    { key: 'renew_node',       label: 'Renew Node',        color: 'text-orange-600' },
    { key: 'update_script',    label: 'Update Script',     color: 'text-indigo-600' },
    { key: 'reboot_vps',       label: 'Reboot VPS',        color: 'text-red-600' },
  ]
  return (
    <div className="relative">
      <button
        onClick={() => setOpen(o => !o)}
        className="px-2 py-1 text-xs bg-gray-100 hover:bg-gray-200 rounded font-medium text-gray-700 whitespace-nowrap"
      >
        Thao tác ▾
      </button>
      {open && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setOpen(false)} />
          <div className="absolute right-0 mt-1 bg-white border border-gray-200 rounded-lg shadow-lg z-20 py-1 min-w-36">
            {actions.map(a => (
              <button
                key={a.key}
                onClick={() => { onAction(node.node_id, a.key); setOpen(false) }}
                className={`w-full text-left px-3 py-1.5 text-xs hover:bg-gray-50 ${a.color}`}
              >
                {a.label}
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  )
}

export default function RenewNodes() {
  const navigate = useNavigate()
  const goBack = useGoBack()
  const [searchParams] = useSearchParams()
  const qc = useQueryClient()
  useEffect(() => { document.title = '💲 Renew Node | ARO Dashboard' }, [])

  const initialTab = (searchParams.get('tab') as Tab | null) ?? 'candidates'
  const [tab, setTab] = useState<Tab>(initialTab)

  // Sync active tab into URL so navigate(-1) restores the correct tab
  const setTabAndUrl = (t: Tab) => {
    setTab(t)
    navigate(`/renew?tab=${t}`, { replace: true })
  }
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [minHistoryDays, setMinHistoryDays] = useState(0)
  const [filterAvgScore, setFilterAvgScore] = useState(true)
  const [filterUptime, setFilterUptime] = useState(false)
  const [historyPage, setHistoryPage] = useState(1)
  const [historyNodeFilter, setHistoryNodeFilter] = useState('')

  // Stats tab state
  const [statsDate, setStatsDate] = useState('')
  const [statsSortBy, setStatsSortBy] = useState('days_0pts')
  const [statsSortDir, setStatsSortDir] = useState<'asc' | 'desc'>('desc')
  const [statsPage, setStatsPage] = useState(1)

  const candidateParams = new URLSearchParams()
  if (minHistoryDays > 0) candidateParams.set('min_history_days', String(minHistoryDays))
  candidateParams.set('filter_avg_score', String(filterAvgScore))
  candidateParams.set('filter_uptime', String(filterUptime))

  const { data: candidates, isLoading, refetch, isFetching } = useQuery<RenewCandidatesResponse>({
    queryKey: ['renew-candidates', minHistoryDays, filterAvgScore, filterUptime],
    queryFn: () => api.get(`/renew/candidates?${candidateParams}`).then(r => r.data),
    refetchInterval: 60_000,
  })

  const historyParams = new URLSearchParams()
  historyParams.set('page', String(historyPage))
  historyParams.set('page_size', '50')
  if (historyNodeFilter) historyParams.set('node_id', historyNodeFilter)

  const { data: history, isLoading: histLoading } = useQuery<RenewHistoryResponse>({
    queryKey: ['renew-history', historyPage, historyNodeFilter],
    queryFn: () => api.get(`/renew/history?${historyParams}`).then(r => r.data),
    enabled: tab === 'history',
  })

  const statsParams = new URLSearchParams()
  if (statsDate) statsParams.set('date', statsDate)
  statsParams.set('sort_by', statsSortBy)
  statsParams.set('sort_dir', statsSortDir)
  statsParams.set('page', String(statsPage))
  statsParams.set('page_size', '50')

  const { data: statsData, isLoading: statsLoading, refetch: statsRefetch, isFetching: statsFetching } = useQuery<RenewStatsResponse>({
    queryKey: ['renew-stats', statsDate, statsSortBy, statsSortDir, statsPage],
    queryFn: () => api.get(`/dashboard/renew-stats?${statsParams}`).then(r => r.data),
    enabled: tab === 'stats',
  })

  const renewOne = useMutation({
    mutationFn: (node_id: string) => api.post('/renew/trigger', { node_id }).then(r => r.data),
    onSuccess: (_, node_id) => {
      qc.invalidateQueries({ queryKey: ['renew-candidates'] })
      qc.invalidateQueries({ queryKey: ['renew-history'] })
      alert(`Đã gửi lệnh renew đến ${node_id}.`)
    },
    onError: (err: any) => {
      alert(err?.response?.data?.detail ?? 'Lỗi khi gửi lệnh renew.')
    },
  })

  const renewBulk = useMutation({
    mutationFn: (node_ids: string[]) => api.post('/renew/bulk', { node_ids }).then(r => r.data),
    onSuccess: (result) => {
      qc.invalidateQueries({ queryKey: ['renew-candidates'] })
      qc.invalidateQueries({ queryKey: ['renew-history'] })
      const skippedMsg = result.skipped > 0 ? ` (bỏ qua ${result.skipped} do cooldown)` : ''
      alert(`Đã gửi lệnh renew đến ${result.triggered} node${skippedMsg}.`)
      setSelectedIds(new Set())
    },
    onError: (err: any) => {
      alert(err?.response?.data?.detail ?? 'Lỗi khi gửi lệnh bulk renew.')
    },
  })

  const updateOne = useMutation({
    mutationFn: (node_id: string) =>
      api.post('/dashboard/commands', { node_id, action: 'update_script' }).then(r => r.data),
    onSuccess: (_, node_id) => {
      alert(`Đã gửi lệnh cập nhật script đến ${node_id}.`)
    },
    onError: (err: any) => {
      alert(err?.response?.data?.detail ?? 'Lỗi khi gửi lệnh cập nhật script.')
    },
  })

  const updateBulk = useMutation({
    mutationFn: (node_ids: string[]) =>
      api.post('/dashboard/commands/bulk', { action: 'update_script', node_ids }).then(r => r.data),
    onSuccess: (result) => {
      const skippedMsg = result.skipped > 0 ? ` (bỏ qua ${result.skipped})` : ''
      alert(`Đã gửi lệnh cập nhật script đến ${result.created} node${skippedMsg}.`)
    },
    onError: (err: any) => {
      alert(err?.response?.data?.detail ?? 'Lỗi khi gửi lệnh bulk cập nhật script.')
    },
  })

  const statsAction = useMutation({
    mutationFn: ({ node_id, action }: { node_id: string; action: string }) => {
      if (action === 'renew_node') {
        return api.post('/renew/trigger', { node_id }).then(r => r.data)
      }
      return api.post('/dashboard/commands', { node_id, action }).then(r => r.data)
    },
    onSuccess: (_, { node_id, action }) => {
      if (action === 'renew_node') {
        qc.invalidateQueries({ queryKey: ['renew-history'] })
      }
      qc.invalidateQueries({ queryKey: ['renew-stats'] })
      alert(`Đã gửi lệnh đến ${node_id}.`)
    },
    onError: (err: any) => {
      alert(err?.response?.data?.detail ?? 'Lỗi khi gửi lệnh.')
    },
  })

  const handleStatsAction = (nodeId: string, action: string) => {
    const labels: Record<string, string> = {
      restart_aro: 'Restart ARO',
      restart_watchdog: 'Restart Watchdog',
      renew_node: 'Renew Node',
      update_script: 'Update Script',
      reboot_vps: 'Reboot VPS',
    }
    if (!confirm(`${labels[action] ?? action} node ${nodeId}?`)) return
    statsAction.mutate({ node_id: nodeId, action })
  }

  const handleStatsSort = (col: string) => {
    if (statsSortBy === col) {
      setStatsSortDir(d => d === 'asc' ? 'desc' : 'asc')
    } else {
      setStatsSortBy(col)
      setStatsSortDir('desc')
    }
    setStatsPage(1)
  }

  const handleBulkUpdate = () => {
    const ids = [...selectedIds]
    if (ids.length === 0) { alert('Chưa chọn node nào.'); return }
    if (!confirm(`Gửi lệnh cập nhật script đến ${ids.length} node đã chọn?`)) return
    updateBulk.mutate(ids)
  }

  const handleRenewOne = (node: RenewCandidate) => {
    if (node.cooldown_until) {
      alert(`Node đang trong cooldown. Vui lòng chờ thêm.`)
      return
    }
    if (!confirm(`Renew node ${node.node_id}?\n\nSerial hiện tại: ${node.serial ?? 'N/A'}\nThao tác này sẽ xóa và cài lại ARO.`)) return
    renewOne.mutate(node.node_id)
  }

  const handleBulkRenew = () => {
    const ids = [...selectedIds]
    if (ids.length === 0) { alert('Chưa chọn node nào.'); return }
    if (!confirm(`Bulk renew ${ids.length} node đã chọn?\n\nSerial của các node sẽ được lưu lại trước khi renew.\nThao tác này sẽ xóa và cài lại ARO trên tất cả node đó.`)) return
    renewBulk.mutate(ids)
  }

  const toggleSelect = (id: string) => {
    setSelectedIds(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const selectableNodes = (candidates?.nodes ?? []).filter(n => !n.cooldown_until)
  const allSelected = selectableNodes.length > 0 && selectableNodes.every(n => selectedIds.has(n.node_id))
  const someSelected = selectableNodes.some(n => selectedIds.has(n.node_id))

  const toggleSelectAll = () => {
    if (allSelected) {
      const next = new Set(selectedIds)
      selectableNodes.forEach(n => next.delete(n.node_id))
      setSelectedIds(next)
    } else {
      const next = new Set(selectedIds)
      selectableNodes.forEach(n => next.add(n.node_id))
      setSelectedIds(next)
    }
  }

  const nodes = candidates?.nodes ?? []
  const selectedCount = selectedIds.size

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-[1880px] mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <button
              onClick={goBack}
              className="flex items-center gap-1.5 text-sm text-gray-500 hover:text-gray-800 transition-colors"
            >
              <ArrowLeft size={15} />
              Dashboard
            </button>
            <span className="text-gray-300">|</span>
            <div>
              <h1 className="text-lg font-bold text-gray-800 flex items-center gap-2">
                <RotateCcw size={18} className="text-orange-500" />
                Renew Node
              </h1>
              <p className="text-xs text-gray-400">
                Lọc node theo TB điểm/ngày và uptime
              </p>
            </div>
          </div>
          <button
            onClick={() => tab === 'stats' ? statsRefetch() : refetch()}
            disabled={isFetching || statsFetching}
            className="flex items-center gap-1.5 px-3 py-1.5 text-sm text-gray-600 hover:text-gray-900 hover:bg-gray-100 rounded-lg transition-colors disabled:opacity-50"
          >
            <RefreshCw size={14} className={(isFetching || statsFetching) ? 'animate-spin' : ''} />
            Làm mới
          </button>
        </div>
      </header>

      <main className="max-w-[1880px] mx-auto px-4 py-4 space-y-4">
        {/* Tabs */}
        <div className="flex gap-1 border-b border-gray-200">
          <button
            onClick={() => setTabAndUrl('candidates')}
            className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors ${
              tab === 'candidates'
                ? 'border-orange-500 text-orange-600'
                : 'border-transparent text-gray-500 hover:text-gray-700'
            }`}
          >
            <span className="flex items-center gap-1.5">
              <AlertTriangle size={14} />
              Cần Renew
              {candidates && (
                <span className="ml-1 bg-orange-100 text-orange-700 text-xs px-1.5 py-0.5 rounded-full font-semibold">
                  {candidates.total}
                </span>
              )}
            </span>
          </button>
          <button
            onClick={() => setTabAndUrl('history')}
            className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors ${
              tab === 'history'
                ? 'border-orange-500 text-orange-600'
                : 'border-transparent text-gray-500 hover:text-gray-700'
            }`}
          >
            <span className="flex items-center gap-1.5">
              <History size={14} />
              Lịch sử Renew
            </span>
          </button>
          <button
            onClick={() => setTabAndUrl('stats')}
            className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors ${
              tab === 'stats'
                ? 'border-violet-600 text-violet-700'
                : 'border-transparent text-gray-500 hover:text-gray-700'
            }`}
          >
            <span className="flex items-center gap-1.5">
              <BarChart2 size={14} />
              Thống kê
              {statsData && (
                <span className="ml-1 bg-violet-100 text-violet-700 text-xs px-1.5 py-0.5 rounded-full font-semibold">
                  {statsData.total}
                </span>
              )}
            </span>
          </button>
        </div>

        {/* Candidates Tab */}
        {tab === 'candidates' && (
          <div className="space-y-3">
            <div className="flex items-center gap-3 flex-wrap">
              <div className="flex items-center gap-3 bg-gray-50 border border-gray-200 rounded-lg px-3 py-1.5">
                <span className="text-xs text-gray-500 font-medium whitespace-nowrap">Điều kiện:</span>
                <label className="flex items-center gap-1.5 cursor-pointer select-none">
                  <input
                    type="checkbox"
                    checked={filterAvgScore}
                    onChange={e => { setFilterAvgScore(e.target.checked); setSelectedIds(new Set()) }}
                    className="accent-orange-500 cursor-pointer"
                  />
                  <span className="text-xs text-gray-700 whitespace-nowrap">TB điểm/ngày = 0</span>
                </label>
                <label className="flex items-center gap-1.5 cursor-pointer select-none">
                  <input
                    type="checkbox"
                    checked={filterUptime}
                    onChange={e => { setFilterUptime(e.target.checked); setSelectedIds(new Set()) }}
                    className="accent-orange-500 cursor-pointer"
                  />
                  <span className="text-xs text-gray-700 whitespace-nowrap">Uptime = 0</span>
                </label>
              </div>

              <div className="h-4 w-px bg-gray-200" />

              <div className="flex items-center gap-2 text-sm">
                <span className="text-gray-500 whitespace-nowrap">Bỏ qua node có lịch sử &lt;</span>
                <select
                  value={minHistoryDays}
                  onChange={e => { setMinHistoryDays(Number(e.target.value)); setSelectedIds(new Set()) }}
                  className={`border rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-300 transition-colors ${
                    minHistoryDays > 0 ? 'border-blue-300 bg-blue-50 text-blue-700' : 'border-gray-200 text-gray-600'
                  }`}
                >
                  {[0, 1, 2, 3, 4, 5, 6, 7].map(d => (
                    <option key={d} value={d}>{d === 0 ? 'Không lọc' : `${d} ngày`}</option>
                  ))}
                </select>
              </div>

              {selectedCount > 0 && (
                <>
                  <div className="h-4 w-px bg-gray-200" />
                  <span className="text-xs text-gray-500">Đã chọn {selectedCount} node</span>
                  <button onClick={() => setSelectedIds(new Set())} className="text-xs text-gray-400 hover:text-gray-600 hover:underline">
                    Bỏ chọn
                  </button>
                  <div className="h-4 w-px bg-gray-200" />
                  <button
                    onClick={handleBulkRenew}
                    disabled={renewBulk.isPending}
                    className="flex items-center gap-1.5 px-3 py-1.5 bg-orange-500 hover:bg-orange-600 disabled:bg-orange-300 text-white text-sm rounded-lg font-medium transition-colors"
                  >
                    <RotateCcw size={13} />
                    Bulk Renew ({selectedCount} node)
                  </button>
                  <button
                    onClick={handleBulkUpdate}
                    disabled={updateBulk.isPending}
                    className="flex items-center gap-1.5 px-3 py-1.5 bg-indigo-600 hover:bg-indigo-700 disabled:bg-indigo-300 text-white text-sm rounded-lg font-medium transition-colors"
                  >
                    <Download size={13} />
                    Bulk Cập nhật Script ({selectedCount} node)
                  </button>
                </>
              )}
            </div>

            <div className="bg-white rounded-xl shadow-sm overflow-hidden">
              {isLoading ? (
                <div className="text-center py-12 text-gray-400">Đang tải...</div>
              ) : nodes.length === 0 ? (
                <div className="text-center py-16">
                  <div className="text-4xl mb-2">✅</div>
                  <p className="text-gray-500 font-medium">Không có node nào cần renew</p>
                  <p className="text-gray-400 text-sm mt-1">Tất cả node đều có điểm hoạt động bình thường.</p>
                </div>
              ) : (
                <table className="w-full text-sm">
                  <thead className="bg-gray-50 border-b border-gray-100">
                    <tr>
                      <th className="w-8 px-3 py-2.5">
                        <input
                          type="checkbox"
                          checked={allSelected}
                          ref={el => { if (el) el.indeterminate = someSelected && !allSelected }}
                          onChange={toggleSelectAll}
                          disabled={selectableNodes.length === 0}
                          className="rounded border-gray-300 accent-orange-500 cursor-pointer disabled:cursor-not-allowed"
                        />
                      </th>
                      <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Hostname</th>
                      <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Account</th>
                      <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Serial</th>
                      <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Trạng thái</th>
                      <th className="text-right px-3 py-2.5 font-semibold text-gray-600">TB điểm/ngày</th>
                      <th className="text-right px-3 py-2.5 font-semibold text-gray-600">Uptime</th>
                      <th className="text-center px-3 py-2.5 font-semibold text-gray-600">Đã renew</th>
                      <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Lần cuối</th>
                      <th className="px-3 py-2.5"></th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-50">
                    {nodes.map(node => {
                      const inCooldown = !!node.cooldown_until
                      const isSelected = selectedIds.has(node.node_id)
                      return (
                        <tr
                          key={node.node_id}
                          className={`hover:bg-gray-50 transition-colors ${inCooldown ? 'opacity-60' : ''} ${isSelected ? 'bg-orange-50' : ''}`}
                        >
                          <td className="px-3 py-2.5">
                            <input
                              type="checkbox"
                              checked={isSelected}
                              disabled={inCooldown}
                              onChange={() => toggleSelect(node.node_id)}
                              className="accent-orange-500"
                            />
                          </td>
                          <td className="px-3 py-2.5">
                            <button
                              onClick={() => navigate(`/nodes/${encodeURIComponent(node.node_id)}`)}
                              className="font-mono text-xs text-blue-600 hover:underline"
                            >
                              {node.node_id}
                            </button>
                            {node.is_stale && (
                              <span className="ml-1 text-xs text-gray-400">(stale)</span>
                            )}
                          </td>
                          <td className="px-3 py-2.5 text-gray-600 text-xs">{node.account ?? '—'}</td>
                          <td className="px-3 py-2.5 font-mono text-xs text-gray-500">{node.serial ?? '—'}</td>
                          <td className="px-3 py-2.5"><StatusBadge status={node.aro_status} /></td>
                          <td className="px-3 py-2.5 text-right text-red-600 font-medium">
                            {node.avg_score != null ? node.avg_score.toFixed(1) : '0.0'}
                          </td>
                          <td className="px-3 py-2.5 text-right text-red-600 font-medium">
                            {node.uptime_ratio != null ? `${(node.uptime_ratio * 100).toFixed(0)}%` : '—'}
                          </td>
                          <td className="px-3 py-2.5 text-center">
                            {node.renew_count > 0 ? (
                              <span className={`px-2 py-0.5 rounded-full text-xs font-bold ${
                                node.renew_count >= 3 ? 'bg-red-100 text-red-700' :
                                node.renew_count >= 2 ? 'bg-orange-100 text-orange-700' :
                                'bg-blue-100 text-blue-700'
                              }`}>
                                {node.renew_count}×
                              </span>
                            ) : (
                              <span className="text-gray-300 text-xs">—</span>
                            )}
                          </td>
                          <td className="px-3 py-2.5 text-xs text-gray-400">
                            {inCooldown ? (
                              <span className="flex items-center gap-1 text-amber-600">
                                <Clock size={11} />
                                Cooldown {formatTime(node.cooldown_until)}
                              </span>
                            ) : (
                              node.last_renewed_at ? formatTime(node.last_renewed_at) : '—'
                            )}
                          </td>
                          <td className="px-3 py-2.5">
                            <div className="flex items-center gap-1.5">
                              <button
                                onClick={() => handleRenewOne(node)}
                                disabled={inCooldown || renewOne.isPending}
                                className="flex items-center gap-1 px-2.5 py-1 bg-orange-500 hover:bg-orange-600 disabled:bg-gray-200 disabled:text-gray-400 text-white text-xs rounded-md font-medium transition-colors whitespace-nowrap"
                                title={inCooldown ? 'Đang trong thời gian cooldown' : 'Renew node này'}
                              >
                                <RotateCcw size={11} />
                                Renew
                              </button>
                              <button
                                onClick={() => {
                                  if (!confirm(`Cập nhật script cho node ${node.node_id}?`)) return
                                  updateOne.mutate(node.node_id)
                                }}
                                disabled={updateOne.isPending}
                                className="flex items-center gap-1 px-2.5 py-1 bg-indigo-500 hover:bg-indigo-600 disabled:bg-gray-200 disabled:text-gray-400 text-white text-xs rounded-md font-medium transition-colors whitespace-nowrap"
                                title="Cập nhật script cho node này"
                              >
                                <Download size={11} />
                                Script
                              </button>
                            </div>
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              )}
            </div>

            <div className="bg-amber-50 border border-amber-200 rounded-lg px-4 py-3 text-xs text-amber-800 space-y-1">
              <p className="font-semibold">Lưu ý:</p>
              <ul className="list-disc list-inside space-y-0.5">
                <li>Danh sách <strong>loại trừ node Unbound</strong>. Chọn điều kiện lọc bằng 2 checkbox phía trên.</li>
                <li>Serial của mỗi node được lưu lại trước khi renew để tra cứu sau.</li>
                <li>Cooldown <strong>4 giờ</strong> giữa các lần renew trên cùng 1 node.</li>
                <li>Tối đa <strong>5 node</strong> renew cùng lúc trên toàn hệ thống.</li>
                <li>Lệnh renew sẽ được node thực thi khi nó gọi API báo cáo lần tiếp theo.</li>
              </ul>
            </div>
          </div>
        )}

        {/* History Tab */}
        {tab === 'history' && (
          <div className="space-y-3">
            <div className="flex items-center gap-2">
              <input
                type="text"
                value={historyNodeFilter}
                onChange={e => { setHistoryNodeFilter(e.target.value); setHistoryPage(1) }}
                placeholder="Lọc theo hostname..."
                className="border border-gray-200 rounded-lg px-3 py-1.5 text-sm w-64 focus:outline-none focus:ring-2 focus:ring-orange-300"
              />
              {historyNodeFilter && (
                <button
                  onClick={() => { setHistoryNodeFilter(''); setHistoryPage(1) }}
                  className="text-xs text-gray-400 hover:text-gray-600"
                >
                  Xóa
                </button>
              )}
            </div>

            <div className="bg-white rounded-xl shadow-sm overflow-auto max-h-[calc(100vh-220px)]">
              {histLoading ? (
                <div className="text-center py-12 text-gray-400">Đang tải...</div>
              ) : !history || history.logs.length === 0 ? (
                <div className="text-center py-16">
                  <p className="text-gray-400">Chưa có lịch sử renew.</p>
                </div>
              ) : (
                <>
                  <table className="w-full text-sm">
                    <thead className="bg-gray-50 border-b border-gray-100 sticky top-0 z-10">
                      <tr>
                        <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Thời gian</th>
                        <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Hostname</th>
                        <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Account trước renew</th>
                        <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Account hiện tại</th>
                        <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Serial trước → sau</th>
                        <th className="text-right px-3 py-2.5 font-semibold text-gray-600">Điểm hôm qua</th>
                        <th className="text-center px-3 py-2.5 font-semibold text-gray-600">Lần #</th>
                        <th className="text-center px-3 py-2.5 font-semibold text-gray-600">Trạng thái</th>
                        <th className="text-center px-3 py-2.5 font-semibold text-gray-600">Theo dõi</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-gray-50">
                      {history.logs.map(log => (
                        <tr key={log.id} className="hover:bg-gray-50">
                          <td className="px-3 py-2.5 text-xs text-gray-500 whitespace-nowrap">
                            {new Date(log.renewed_at + 'Z').toLocaleString('vi-VN')}
                          </td>
                          <td className="px-3 py-2.5">
                            <button
                              onClick={() => navigate(`/nodes/${encodeURIComponent(log.node_id)}`)}
                              className="font-mono text-xs text-blue-600 hover:underline"
                            >
                              {log.node_id}
                            </button>
                          </td>
                          <td className="px-3 py-2.5 text-xs">
                            {log.account_before ? (
                              <span className="text-gray-700 font-medium">{log.account_before}</span>
                            ) : (
                              <span className="text-gray-300">—</span>
                            )}
                          </td>
                          <td className="px-3 py-2.5 text-xs">
                            {log.account ? (
                              <span className="text-green-600 font-medium">
                                {log.account}
                                {log.account === log.account_before ? (
                                  <span className="ml-1 text-green-500 font-normal opacity-70">(giữ nguyên)</span>
                                ) : (
                                  <span className="ml-1 text-green-500 font-normal opacity-70">(mới)</span>
                                )}
                              </span>
                            ) : (
                              <span className="text-red-400 italic">Chưa bind</span>
                            )}
                          </td>
                          <td className="px-3 py-2.5 font-mono text-xs">
                            {log.serial_before ? (
                              <span className="text-gray-600">{log.serial_before}</span>
                            ) : (
                              <span className="text-gray-300">—</span>
                            )}
                            {log.serial_after && log.serial_after !== log.serial_before && (
                              <span className="text-green-600"> → {log.serial_after}</span>
                            )}
                            {log.serial_after && log.serial_after === log.serial_before && (
                              <span className="text-gray-400 text-xs"> (không đổi)</span>
                            )}
                          </td>
                          <td className="px-3 py-2.5 text-right">
                            {log.reward_yesterday != null ? (
                              <span className={`text-xs font-medium ${log.reward_yesterday > 0 ? 'text-green-600' : 'text-red-500'}`}>
                                {log.reward_yesterday}
                              </span>
                            ) : (
                              <span className="text-gray-300 text-xs">—</span>
                            )}
                          </td>
                          <td className="px-3 py-2.5 text-center">
                            <span className="text-xs font-bold text-gray-600">#{log.renew_count}</span>
                          </td>
                          <td className="px-3 py-2.5 text-center">
                            <RenewStatusBadge status={log.status} />
                          </td>
                          <td className="px-3 py-2.5 text-center text-xs">
                            {log.monitored_at ? (
                              <span className="text-green-600" title={new Date(log.monitored_at + 'Z').toLocaleString('vi-VN')}>✓ Đã kiểm tra</span>
                            ) : (
                              <span className="text-gray-300">Chờ 30 phút</span>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>

                  {history.total_pages > 1 && (
                    <div className="flex items-center justify-between px-3 py-2.5 border-t border-gray-100 text-xs text-gray-500">
                      <span>Tổng: {history.total} bản ghi</span>
                      <div className="flex items-center gap-1">
                        <button
                          onClick={() => setHistoryPage(p => Math.max(1, p - 1))}
                          disabled={historyPage === 1}
                          className="px-2 py-1 rounded hover:bg-gray-100 disabled:opacity-40"
                        >
                          ‹
                        </button>
                        <span>{historyPage}/{history.total_pages}</span>
                        <button
                          onClick={() => setHistoryPage(p => Math.min(history.total_pages, p + 1))}
                          disabled={historyPage === history.total_pages}
                          className="px-2 py-1 rounded hover:bg-gray-100 disabled:opacity-40"
                        >
                          ›
                        </button>
                      </div>
                    </div>
                  )}
                </>
              )}
            </div>
          </div>
        )}

        {/* Stats Tab */}
        {tab === 'stats' && (
          <div className="space-y-3">
            {/* Filters */}
            <div className="flex items-center gap-3 flex-wrap">
              <div className="flex items-center gap-2">
                <span className="text-xs text-gray-500 whitespace-nowrap">Ngày renew:</span>
                <input
                  type="date"
                  value={statsDate}
                  onChange={e => { setStatsDate(e.target.value); setStatsPage(1) }}
                  className="border border-gray-200 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-violet-300"
                />
                {statsDate && (
                  <button
                    onClick={() => { setStatsDate(''); setStatsPage(1) }}
                    className="text-xs text-gray-400 hover:text-gray-600"
                  >
                    Xóa
                  </button>
                )}
              </div>
              {statsData && (
                <span className="text-xs text-gray-500">
                  {statsDate ? `${statsData.total} node renew ngày ${statsDate} chưa có điểm` : `${statsData.total} node renew chưa có điểm`}
                </span>
              )}
            </div>

            <div className="bg-white rounded-xl shadow-sm overflow-hidden">
              {statsLoading ? (
                <div className="text-center py-12 text-gray-400">Đang tải...</div>
              ) : !statsData || statsData.nodes.length === 0 ? (
                <div className="text-center py-16">
                  <div className="text-4xl mb-2">✅</div>
                  <p className="text-gray-500 font-medium">
                    {statsDate ? `Không có node renew ngày ${statsDate} nào đang 0 điểm` : 'Không có node nào đang 0 điểm sau renew'}
                  </p>
                </div>
              ) : (
                <>
                  <div className="overflow-x-auto">
                    <table className="w-full text-sm">
                      <thead className="bg-gray-50 border-b border-gray-100">
                        <tr>
                          <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Hostname</th>
                          <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Account</th>
                          <th
                            className="text-left px-3 py-2.5 font-semibold text-gray-600 cursor-pointer hover:text-gray-800 select-none whitespace-nowrap"
                            onClick={() => handleStatsSort('renewed_at')}
                          >
                            Ngày renew <SortIcon col="renewed_at" sortBy={statsSortBy} sortDir={statsSortDir} />
                          </th>
                          <th
                            className="text-right px-3 py-2.5 font-semibold text-gray-600 cursor-pointer hover:text-gray-800 select-none whitespace-nowrap"
                            onClick={() => handleStatsSort('days_0pts')}
                          >
                            Số ngày 0 điểm <SortIcon col="days_0pts" sortBy={statsSortBy} sortDir={statsSortDir} />
                          </th>
                          <th className="text-center px-3 py-2.5 font-semibold text-gray-600 whitespace-nowrap">Số lần renew</th>
                          <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Trạng thái</th>
                          <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Last seen</th>
                          <th className="px-3 py-2.5"></th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-gray-50">
                        {statsData.nodes.map(node => (
                          <tr key={node.node_id} className={`hover:bg-gray-50 transition-colors ${node.is_stale ? 'opacity-60' : ''}`}>
                            <td className="px-3 py-2.5">
                              <button
                                onClick={() => navigate(`/nodes/${encodeURIComponent(node.node_id)}`)}
                                className="font-mono text-xs text-blue-600 hover:underline"
                              >
                                {node.node_id}
                              </button>
                              {node.is_stale && <span className="ml-1 text-xs text-gray-400">(stale)</span>}
                            </td>
                            <td className="px-3 py-2.5 text-gray-600 text-xs">{node.account ?? '—'}</td>
                            <td className="px-3 py-2.5 text-xs text-gray-500 whitespace-nowrap">
                              {new Date(node.renewed_at + 'Z').toLocaleDateString('vi-VN')}
                            </td>
                            <td className="px-3 py-2.5 text-right">
                              <span className={`text-xs font-bold ${node.days_0pts >= 3 ? 'text-red-600' : node.days_0pts >= 2 ? 'text-orange-600' : 'text-yellow-600'}`}>
                                {node.days_0pts} ngày
                              </span>
                            </td>
                            <td className="px-3 py-2.5 text-center">
                              {node.renew_count > 0 ? (
                                <span className={`px-2 py-0.5 rounded-full text-xs font-bold ${
                                  node.renew_count >= 3 ? 'bg-red-100 text-red-700' :
                                  node.renew_count >= 2 ? 'bg-orange-100 text-orange-700' :
                                  'bg-blue-100 text-blue-700'
                                }`}>
                                  {node.renew_count}×
                                </span>
                              ) : (
                                <span className="text-gray-300 text-xs">—</span>
                              )}
                            </td>
                            <td className="px-3 py-2.5"><StatusBadge status={node.aro_status} /></td>
                            <td className="px-3 py-2.5 text-xs text-gray-400 whitespace-nowrap">
                              {formatTime(node.last_seen)}
                            </td>
                            <td className="px-3 py-2.5">
                              <ActionMenu node={node} onAction={handleStatsAction} />
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>

                  {statsData.total_pages > 1 && (
                    <div className="flex items-center justify-between px-3 py-2.5 border-t border-gray-100 text-xs text-gray-500">
                      <span>Tổng: {statsData.total} node</span>
                      <div className="flex items-center gap-1">
                        <button
                          onClick={() => setStatsPage(p => Math.max(1, p - 1))}
                          disabled={statsPage === 1}
                          className="px-2 py-1 rounded hover:bg-gray-100 disabled:opacity-40"
                        >
                          ‹
                        </button>
                        <span>{statsPage}/{statsData.total_pages}</span>
                        <button
                          onClick={() => setStatsPage(p => Math.min(statsData.total_pages, p + 1))}
                          disabled={statsPage === statsData.total_pages}
                          className="px-2 py-1 rounded hover:bg-gray-100 disabled:opacity-40"
                        >
                          ›
                        </button>
                      </div>
                    </div>
                  )}
                </>
              )}
            </div>
          </div>
        )}
      </main>
    </div>
  )
}
