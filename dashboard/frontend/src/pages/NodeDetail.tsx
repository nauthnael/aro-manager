import { useEffect, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Pencil, Check, X, RefreshCw, ShieldAlert, Tag as TagIcon } from 'lucide-react'
import { formatDistanceToNow, format } from 'date-fns'
import {
  LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, ReferenceLine,
} from 'recharts'
import { NodeDetailResponse, RestartEvent, ErrorEvent, DailyScore, ERROR_LABELS, ERROR_COLORS, ErrorType, TagOut } from '../types'
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

function NodeTagsEditor({ nodeId, currentTags }: { nodeId: string; currentTags: { id: number; name: string; color: string }[] }) {
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  const { data: allTags = [] } = useQuery<TagOut[]>({
    queryKey: ['tags'],
    queryFn: () => api.get('/tags').then(r => r.data),
  })

  const setTags = useMutation({
    mutationFn: (tag_ids: number[]) =>
      api.put(`/dashboard/nodes/${encodeURIComponent(nodeId)}/tags`, { tag_ids }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['node', nodeId] }),
  })

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [])

  const currentIds = new Set(currentTags.map(t => t.id))

  const toggle = (tagId: number) => {
    const next = new Set(currentIds)
    if (next.has(tagId)) next.delete(tagId)
    else next.add(tagId)
    setTags.mutate([...next])
  }

  return (
    <div className="mt-4 pt-4 border-t border-gray-100">
      <div className="flex items-center gap-2 mb-2">
        <p className="text-xs text-gray-500">Tags</p>
        <div ref={ref} className="relative">
          <button
            onClick={() => setOpen(o => !o)}
            className="flex items-center gap-1 px-2 py-0.5 text-xs text-gray-500 border border-dashed border-gray-300 rounded-full hover:border-blue-400 hover:text-blue-600 transition-colors"
          >
            <TagIcon size={11} /> Thêm tag
          </button>
          {open && (
            <div className="absolute left-0 top-7 z-20 w-52 bg-white border border-gray-200 rounded-xl shadow-lg py-1">
              {allTags.length === 0 ? (
                <p className="text-xs text-gray-400 px-3 py-2 italic">Chưa có tag nào. Tạo tag trong Cài đặt.</p>
              ) : (
                allTags.map(tag => (
                  <button
                    key={tag.id}
                    onClick={() => toggle(tag.id)}
                    className="w-full flex items-center gap-2 px-3 py-1.5 hover:bg-gray-50 text-left"
                  >
                    <span
                      className="w-3 h-3 rounded-full flex-shrink-0 border-2"
                      style={{
                        backgroundColor: currentIds.has(tag.id) ? tag.color : 'transparent',
                        borderColor: tag.color,
                      }}
                    />
                    <span className="text-sm text-gray-700 flex-1">{tag.name}</span>
                    {currentIds.has(tag.id) && <Check size={12} className="text-blue-500" />}
                  </button>
                ))
              )}
            </div>
          )}
        </div>
      </div>
      <div className="flex flex-wrap gap-1.5">
        {currentTags.length === 0 ? (
          <span className="text-xs text-gray-300 italic">Chưa có tag</span>
        ) : (
          currentTags.map(t => (
            <span
              key={t.id}
              className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium text-white"
              style={{ backgroundColor: t.color }}
            >
              {t.name}
              <button
                onClick={() => toggle(t.id)}
                className="opacity-70 hover:opacity-100 transition-opacity ml-0.5"
              >
                <X size={11} />
              </button>
            </span>
          ))
        )}
      </div>
    </div>
  )
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

  const saveNotes = useMutation({
    mutationFn: () => api.put(`/dashboard/nodes/${encodeURIComponent(nodeId!)}/notes`, { notes: notesValue }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['node', nodeId] })
      setEditingNotes(false)
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

          {/* Tags */}
          <NodeTagsEditor nodeId={node.node_id} currentTags={node.tags} />

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

        {/* Control */}
        <div className="bg-white rounded-xl shadow-sm p-5">
          <h2 className="text-sm font-semibold text-gray-700 mb-4">Điều khiển node</h2>
          <CommandPanel nodeId={node.node_id} />
        </div>
      </main>
    </div>
  )
}
