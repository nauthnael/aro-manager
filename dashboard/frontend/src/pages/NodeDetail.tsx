import { useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Pencil, Check, X, RefreshCw, ShieldAlert, RotateCcw, Clock } from 'lucide-react'
import { formatDistanceToNow, format, parseISO } from 'date-fns'
import { vi } from 'date-fns/locale'
import {
  LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, ReferenceLine,
} from 'recharts'
import { NodeDetailResponse, RestartEvent, ErrorEvent, DailyScore, ERROR_LABELS, ERROR_COLORS, ErrorType, RenewHistoryResponse } from '../types'
import api from '../api/client'
import StatusBadge from '../components/StatusBadge'
import RewardChart from '../components/RewardChart'
import CommandPanel from '../components/CommandPanel'
import ScreenshotPanel from '../components/ScreenshotPanel'

function scoreColor(s: number) {
  if (s >= 950) return '#16a34a'
  if (s >= 800) return '#f59e0b'
  if (s >= 600) return '#f97316'
  return '#dc2626'
}

function InfoRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <p className="text-xs text-gray-500">{label}</p>
      <p className="text-sm font-medium text-gray-800 mt-0.5">{value ?? '—'}</p>
    </div>
  )
}

export default function NodeDetail() {
  const { nodeId } = useParams<{ nodeId: string }>()
  const navigate = useNavigate()
  const qc = useQueryClient()

  const [editingNotes, setEditingNotes] = useState(false)
  const [notesValue, setNotesValue] = useState('')

  const { data, isLoading } = useQuery<NodeDetailResponse>({
    queryKey: ['node', nodeId],
    queryFn: () => api.get(`/dashboard/nodes/${encodeURIComponent(nodeId!)}`).then(r => r.data),
    refetchInterval: 15_000,
    enabled: !!nodeId,
  })

  const { data: scoresData } = useQuery<{ scores: DailyScore[]; score_base: number }>({
    queryKey: ['node-scores', nodeId],
    queryFn: () => api.get(`/errors/${encodeURIComponent(nodeId!)}/scores?days=30`).then(r => r.data),
    refetchInterval: 60_000,
    enabled: !!nodeId,
  })

  const { data: eventsData } = useQuery<{ events: ErrorEvent[] }>({
    queryKey: ['node-errors', nodeId],
    queryFn: () => api.get(`/errors/${encodeURIComponent(nodeId!)}/events?days=30`).then(r => r.data),
    refetchInterval: 60_000,
    enabled: !!nodeId,
  })

  const { data: renewHistory } = useQuery<RenewHistoryResponse>({
    queryKey: ['renew-history-node', nodeId],
    queryFn: () => api.get(`/renew/history?node_id=${encodeURIComponent(nodeId!)}&page_size=5`).then(r => r.data),
    refetchInterval: 60_000,
    enabled: !!nodeId,
  })

  const saveNotes = useMutation({
    mutationFn: () => api.put(`/dashboard/nodes/${encodeURIComponent(nodeId!)}/notes`, { notes: notesValue }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['node', nodeId] })
      setEditingNotes(false)
    },
  })

  const renewNode = useMutation({
    mutationFn: () => api.post('/renew/trigger', { node_id: nodeId }).then(r => r.data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['renew-history-node', nodeId] })
      qc.invalidateQueries({ queryKey: ['node', nodeId] })
      alert(`Đã gửi lệnh renew đến ${nodeId}.\nNode sẽ thực thi khi báo cáo lần tiếp theo.`)
    },
    onError: (err: any) => {
      alert(err?.response?.data?.detail ?? 'Lỗi khi gửi lệnh renew.')
    },
  })

  const startEditNotes = () => {
    setNotesValue(data?.node.notes ?? '')
    setEditingNotes(true)
  }

  if (isLoading) {
    return (
      <div className="min-h-screen bg-gray-100 flex items-center justify-center text-gray-400">
        Đang tải...
      </div>
    )
  }
  if (!data) return null

  const { node, history, restart_events } = data

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-4xl mx-auto px-4 py-3 flex items-center gap-3">
          <button onClick={() => navigate('/')} className="p-1 text-gray-500 hover:text-gray-800">
            <ArrowLeft size={18} />
          </button>
          <div className="flex-1 min-w-0">
            <h1 className="text-base font-bold font-mono text-gray-800 truncate">{node.node_id}</h1>
            <p className="text-xs text-gray-400 truncate">{node.account ?? '—'}</p>
          </div>
          <StatusBadge status={node.aro_status} isStale={node.is_stale} />
          <button
            onClick={() => {
              if (!confirm(`Renew node ${node.node_id}?\n\nSerial hiện tại: ${node.serial ?? 'N/A'}\nThao tác này sẽ xóa và cài lại ARO Desktop.`)) return
              renewNode.mutate()
            }}
            disabled={renewNode.isPending}
            className="flex items-center gap-1.5 px-3 py-1.5 bg-orange-500 hover:bg-orange-600 disabled:bg-orange-300 text-white text-sm rounded-lg font-medium transition-colors whitespace-nowrap"
            title="Renew: xóa và cài lại ARO Desktop"
          >
            <RotateCcw size={14} className={renewNode.isPending ? 'animate-spin' : ''} />
            Renew
            {(node.renew_count ?? 0) > 0 && (
              <span className="bg-orange-400 text-white text-xs px-1.5 py-0.5 rounded-full font-bold">
                {node.renew_count}×
              </span>
            )}
          </button>
        </div>
      </header>

      <main className="max-w-4xl mx-auto px-4 py-5 space-y-5">
        {/* Info grid */}
        <div className="bg-white rounded-xl shadow-sm p-5">
          <h2 className="text-sm font-semibold text-gray-700 mb-4">Thông tin node</h2>
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-x-6 gap-y-4">
            <InfoRow label="Serial" value={node.serial} />
            <InfoRow label="Public IP" value={node.public_ip} />
            <InfoRow label="Proxy" value={node.proxy_host ? `${node.proxy_host}:${node.proxy_port}` : null} />
            <InfoRow
              label="Proxy OK"
              value={
                node.proxy_ok == null ? null : node.proxy_ok
                  ? <span className="text-green-600">✓ OK</span>
                  : <span className="text-red-600">✗ Down</span>
              }
            />
            <InfoRow
              label="Uptime"
              value={node.uptime_ratio != null ? `${(node.uptime_ratio * 100).toFixed(1)}%` : null}
            />
            <InfoRow label="Script Version" value={node.script_version} />
            <InfoRow
              label="Tổng điểm"
              value={node.total_score != null ? node.total_score.toLocaleString() + ' pts' : null}
            />
            <InfoRow
              label="TB/ngày"
              value={node.avg_score != null ? node.avg_score.toLocaleString() + ' pts' : null}
            />
            <InfoRow
              label="Điểm hôm qua"
              value={node.reward_yesterday != null ? node.reward_yesterday.toLocaleString() + ' pts' : null}
            />
            <InfoRow
              label="Last Seen"
              value={
                node.last_seen
                  ? formatDistanceToNow(new Date(node.last_seen + 'Z'), { addSuffix: true })
                  : 'Never'
              }
            />
          </div>

          {/* Notes */}
          <div className="mt-4 pt-4 border-t border-gray-100">
            <div className="flex items-center justify-between mb-1">
              <p className="text-xs text-gray-500">Ghi chú</p>
              {!editingNotes && (
                <button onClick={startEditNotes} className="text-gray-400 hover:text-gray-700">
                  <Pencil size={13} />
                </button>
              )}
            </div>
            {editingNotes ? (
              <div className="space-y-2">
                <textarea
                  value={notesValue}
                  onChange={e => setNotesValue(e.target.value)}
                  rows={3}
                  className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 resize-none"
                  placeholder="Nhập ghi chú..."
                />
                <div className="flex gap-2">
                  <button
                    onClick={() => saveNotes.mutate()}
                    disabled={saveNotes.isPending}
                    className="flex items-center gap-1 px-3 py-1.5 bg-blue-600 text-white text-xs rounded-lg hover:bg-blue-700 disabled:opacity-50"
                  >
                    <Check size={12} /> Lưu
                  </button>
                  <button
                    onClick={() => setEditingNotes(false)}
                    className="flex items-center gap-1 px-3 py-1.5 bg-gray-100 text-gray-700 text-xs rounded-lg hover:bg-gray-200"
                  >
                    <X size={12} /> Huỷ
                  </button>
                </div>
              </div>
            ) : (
              <p className="text-sm text-gray-600 whitespace-pre-wrap">
                {node.notes || <span className="text-gray-300 italic">Chưa có ghi chú</span>}
              </p>
            )}
          </div>
        </div>

        {/* Reward chart */}
        <div className="bg-white rounded-xl shadow-sm p-5">
          <h2 className="text-sm font-semibold text-gray-700 mb-4">Reward hàng ngày (30 ngày)</h2>
          <RewardChart history={history} />
        </div>

        {/* Periodic restart history */}
        <div className="bg-white rounded-xl shadow-sm p-5">
          <div className="flex items-center gap-2 mb-4">
            <RefreshCw size={15} className="text-gray-500" />
            <h2 className="text-sm font-semibold text-gray-700">Lịch sử tự khởi động lại (30 ngày)</h2>
            <span className="ml-auto text-xs text-gray-400">{restart_events?.length ?? 0} lần</span>
          </div>
          {!restart_events || restart_events.length === 0 ? (
            <p className="text-xs text-gray-400 italic">Chưa có lần tự khởi động nào.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="text-left text-gray-400 border-b border-gray-100">
                    <th className="pb-2 pr-4 font-medium">Thời gian</th>
                    <th className="pb-2 pr-4 font-medium">Kết quả</th>
                    <th className="pb-2 font-medium">Thời gian phục hồi</th>
                  </tr>
                </thead>
                <tbody>
                  {restart_events.map((ev: RestartEvent) => (
                    <tr key={ev.id} className="border-b border-gray-50 last:border-0">
                      <td className="py-1.5 pr-4 text-gray-600 font-mono whitespace-nowrap">
                        {format(new Date(ev.timestamp + 'Z'), 'dd/MM HH:mm:ss')}
                      </td>
                      <td className="py-1.5 pr-4">
                        {ev.success
                          ? <span className="text-green-600 font-medium">✓ Thành công</span>
                          : <span className="text-red-500 font-medium">✗ Thất bại</span>
                        }
                      </td>
                      <td className="py-1.5 text-gray-500">
                        {ev.duration_secs != null ? `${ev.duration_secs}s` : '—'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Daily quality score chart */}
        {scoresData && scoresData.scores.length > 0 && (
          <div className="bg-white rounded-xl shadow-sm p-5">
            <div className="flex items-center gap-2 mb-4">
              <ShieldAlert size={15} className="text-blue-500" />
              <h2 className="text-sm font-semibold text-gray-700">Điểm chất lượng hàng ngày (30 ngày)</h2>
              {(() => {
                const last = scoresData.scores[scoresData.scores.length - 1]
                return last ? (
                  <span
                    className="ml-auto text-sm font-bold"
                    style={{ color: scoreColor(last.score) }}
                  >
                    {last.score.toFixed(1)} / 1000
                  </span>
                ) : null
              })()}
            </div>
            <ResponsiveContainer width="100%" height={160}>
              <LineChart data={scoresData.scores} margin={{ top: 4, right: 8, bottom: 0, left: -20 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="#f3f4f6" />
                <XAxis
                  dataKey="date"
                  tick={{ fontSize: 10, fill: '#9ca3af' }}
                  tickFormatter={d => format(new Date(d + 'T00:00:00'), 'dd/MM')}
                  interval="preserveStartEnd"
                />
                <YAxis
                  domain={[0, 1000]}
                  tick={{ fontSize: 10, fill: '#9ca3af' }}
                  ticks={[0, 500, 800, 950, 1000]}
                />
                <Tooltip
                  formatter={(v: number) => [v.toFixed(1), 'Điểm']}
                  labelFormatter={l => format(new Date(l + 'T00:00:00'), 'dd/MM/yyyy')}
                />
                <ReferenceLine y={950} stroke="#16a34a" strokeDasharray="4 4" strokeWidth={1} />
                <ReferenceLine y={800} stroke="#f59e0b" strokeDasharray="4 4" strokeWidth={1} />
                <Line
                  type="monotone"
                  dataKey="score"
                  stroke="#3b82f6"
                  strokeWidth={2}
                  dot={{ r: 2, fill: '#3b82f6' }}
                  activeDot={{ r: 4 }}
                />
              </LineChart>
            </ResponsiveContainer>
          </div>
        )}

        {/* Error event log */}
        <div className="bg-white rounded-xl shadow-sm p-5">
          <div className="flex items-center gap-2 mb-4">
            <ShieldAlert size={15} className="text-red-500" />
            <h2 className="text-sm font-semibold text-gray-700">Lịch sử lỗi (30 ngày)</h2>
            <span className="ml-auto text-xs text-gray-400">
              {eventsData?.events.length ?? 0} sự kiện
            </span>
          </div>
          {!eventsData || eventsData.events.length === 0 ? (
            <p className="text-xs text-gray-400 italic">Không có lỗi nào trong 30 ngày qua.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="text-left text-gray-400 border-b border-gray-100">
                    <th className="pb-2 pr-4 font-medium">Loại lỗi</th>
                    <th className="pb-2 pr-4 font-medium">Bắt đầu</th>
                    <th className="pb-2 pr-4 font-medium">Kết thúc</th>
                    <th className="pb-2 font-medium">Thời gian</th>
                  </tr>
                </thead>
                <tbody>
                  {eventsData.events.map((ev: ErrorEvent) => (
                    <tr key={ev.id} className="border-b border-gray-50 last:border-0">
                      <td className="py-1.5 pr-4">
                        <span
                          className="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-bold text-white"
                          style={{ backgroundColor: ERROR_COLORS[ev.error_type as ErrorType] }}
                        >
                          {ERROR_LABELS[ev.error_type as ErrorType] ?? ev.error_type}
                        </span>
                        {ev.ongoing && (
                          <span className="ml-1 text-red-500 font-medium animate-pulse">● đang lỗi</span>
                        )}
                      </td>
                      <td className="py-1.5 pr-4 text-gray-600 font-mono whitespace-nowrap">
                        {format(new Date(ev.started_at + 'Z'), 'dd/MM HH:mm')}
                      </td>
                      <td className="py-1.5 pr-4 text-gray-400 font-mono whitespace-nowrap">
                        {ev.ended_at
                          ? format(new Date(ev.ended_at + 'Z'), 'dd/MM HH:mm')
                          : <span className="text-red-400 italic">đang diễn ra</span>}
                      </td>
                      <td className="py-1.5 text-gray-500">
                        {ev.duration_minutes < 60
                          ? `${ev.duration_minutes} phút`
                          : `${Math.floor(ev.duration_minutes / 60)}h${ev.duration_minutes % 60 > 0 ? ` ${ev.duration_minutes % 60}m` : ''}`}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Screenshot */}
        <div className="bg-white rounded-xl shadow-sm p-5">
          <h2 className="text-sm font-semibold text-gray-700 mb-4">Màn hình VNC</h2>
          <ScreenshotPanel nodeId={node.node_id} />
        </div>

        {/* Renew history */}
        {renewHistory && renewHistory.total > 0 && (
          <div className="bg-white rounded-xl shadow-sm p-5">
            <div className="flex items-center gap-2 mb-4">
              <RotateCcw size={15} className="text-orange-500" />
              <h2 className="text-sm font-semibold text-gray-700">Lịch sử Renew</h2>
              <span className="ml-auto text-xs text-gray-400">{renewHistory.total} lần</span>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="text-left text-gray-400 border-b border-gray-100">
                    <th className="pb-2 pr-4 font-medium">Thời gian</th>
                    <th className="pb-2 pr-4 font-medium">Lần #</th>
                    <th className="pb-2 pr-4 font-medium">Serial trước → sau</th>
                    <th className="pb-2 pr-4 font-medium">Trạng thái</th>
                    <th className="pb-2 font-medium">Theo dõi</th>
                  </tr>
                </thead>
                <tbody>
                  {renewHistory.logs.map(log => (
                    <tr key={log.id} className="border-b border-gray-50 last:border-0">
                      <td className="py-1.5 pr-4 text-gray-600 font-mono whitespace-nowrap">
                        {format(parseISO(log.renewed_at + 'Z'), 'dd/MM/yyyy HH:mm')}
                      </td>
                      <td className="py-1.5 pr-4 font-bold text-gray-700">#{log.renew_count}</td>
                      <td className="py-1.5 pr-4 font-mono text-gray-600">
                        {log.serial_before ?? '—'}
                        {log.serial_after && log.serial_after !== log.serial_before && (
                          <span className="text-green-600"> → {log.serial_after}</span>
                        )}
                        {log.serial_after && log.serial_after === log.serial_before && (
                          <span className="text-gray-400"> (không đổi)</span>
                        )}
                      </td>
                      <td className="py-1.5 pr-4">
                        {log.status === 'completed'
                          ? <span className="text-green-600 font-medium">✓ Thành công</span>
                          : log.status === 'failed'
                          ? <span className="text-red-500 font-medium">✗ Thất bại</span>
                          : <span className="text-amber-500 font-medium flex items-center gap-1"><Clock size={10} /> Đang chờ</span>
                        }
                      </td>
                      <td className="py-1.5 text-gray-400">
                        {log.monitored_at
                          ? <span className="text-green-600" title={format(parseISO(log.monitored_at + 'Z'), 'HH:mm dd/MM')}>✓ Đã kiểm tra</span>
                          : <span className="italic">Chờ 30 phút</span>
                        }
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {node.needs_renew && (
              <div className="mt-3 pt-3 border-t border-gray-100 flex items-center gap-2 text-xs text-orange-600">
                <RotateCcw size={12} />
                Node này đang có reward = 0 và uptime = 0 — cần renew.
              </div>
            )}
          </div>
        )}

        {/* Control */}
        <div className="bg-white rounded-xl shadow-sm p-5">
          <h2 className="text-sm font-semibold text-gray-700 mb-4">Điều khiển node</h2>
          <CommandPanel nodeId={node.node_id} />
        </div>
      </main>
    </div>
  )
}
