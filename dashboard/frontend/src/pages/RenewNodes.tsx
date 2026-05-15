import { useState, useEffect } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { ArrowLeft, RefreshCw, RotateCcw, History, AlertTriangle, Clock, Download } from 'lucide-react'
import { formatDistanceToNow, parseISO } from 'date-fns'
import { vi } from 'date-fns/locale'
import api from '../api/client'
import { RenewCandidatesResponse, RenewHistoryResponse, RenewCandidate, RenewLog } from '../types'

type Tab = 'candidates' | 'history'

function StatusBadge({ status }: { status: string | null }) {
  if (!status) return <span className="text-gray-400">—</span>
  const map: Record<string, string> = {
    Online: 'bg-green-100 text-green-800',
    Offline: 'bg-red-100 text-red-800',
    NoInternet: 'bg-yellow-100 text-yellow-800',
    Unbound: 'bg-purple-100 text-purple-800',
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

export default function RenewNodes() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  useEffect(() => { document.title = '💲 Renew Node | ARO Dashboard' }, [])
  const [tab, setTab] = useState<Tab>('candidates')
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [minHistoryDays, setMinHistoryDays] = useState(0)
  const [historyPage, setHistoryPage] = useState(1)
  const [historyNodeFilter, setHistoryNodeFilter] = useState('')

  const candidateParams = new URLSearchParams()
  if (minHistoryDays > 0) candidateParams.set('min_history_days', String(minHistoryDays))

  const { data: candidates, isLoading, refetch, isFetching } = useQuery<RenewCandidatesResponse>({
    queryKey: ['renew-candidates', minHistoryDays],
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
        <div className="max-w-screen-2xl mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <button
              onClick={() => navigate('/')}
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
                Nodes có reward_yesterday = 0 và uptime = 0
              </p>
            </div>
          </div>
          <button
            onClick={() => refetch()}
            disabled={isFetching}
            className="flex items-center gap-1.5 px-3 py-1.5 text-sm text-gray-600 hover:text-gray-900 hover:bg-gray-100 rounded-lg transition-colors disabled:opacity-50"
          >
            <RefreshCw size={14} className={isFetching ? 'animate-spin' : ''} />
            Làm mới
          </button>
        </div>
      </header>

      <main className="max-w-screen-2xl mx-auto px-4 py-4 space-y-4">
        {/* Tabs */}
        <div className="flex gap-1 border-b border-gray-200">
          <button
            onClick={() => setTab('candidates')}
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
            onClick={() => setTab('history')}
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
        </div>

        {/* Candidates Tab */}
        {tab === 'candidates' && (
          <div className="space-y-3">
            {/* Toolbar */}
            <div className="flex items-center gap-3 flex-wrap">
              {/* Filter option */}
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

            {/* Table */}
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
                      <th className="text-right px-3 py-2.5 font-semibold text-gray-600">Reward hôm qua</th>
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
                            {node.reward_yesterday ?? 0}
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

            {/* Info box */}
            <div className="bg-amber-50 border border-amber-200 rounded-lg px-4 py-3 text-xs text-amber-800 space-y-1">
              <p className="font-semibold">Lưu ý:</p>
              <ul className="list-disc list-inside space-y-0.5">
                <li>Danh sách <strong>loại trừ node Unbound</strong> (Unbound thường do lỗi cấu hình, không phải do ARO).</li>
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
            {/* Filter */}
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

            <div className="bg-white rounded-xl shadow-sm overflow-hidden">
              {histLoading ? (
                <div className="text-center py-12 text-gray-400">Đang tải...</div>
              ) : !history || history.logs.length === 0 ? (
                <div className="text-center py-16">
                  <p className="text-gray-400">Chưa có lịch sử renew.</p>
                </div>
              ) : (
                <>
                  <table className="w-full text-sm">
                    <thead className="bg-gray-50 border-b border-gray-100">
                      <tr>
                        <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Thời gian</th>
                        <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Hostname</th>
                        <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Account trước renew</th>
                        <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Account hiện tại</th>
                        <th className="text-left px-3 py-2.5 font-semibold text-gray-600">Serial trước → sau</th>
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
                              log.account !== log.account_before ? (
                                <span className="text-green-600 font-medium">{log.account}</span>
                              ) : (
                                <span className="text-gray-400">{log.account}</span>
                              )
                            ) : (
                              <span className="text-red-400 italic">N/A</span>
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

                  {/* Pagination */}
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
      </main>
    </div>
  )
}
