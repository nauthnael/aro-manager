import { useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Pencil, Check, X } from 'lucide-react'
import { formatDistanceToNow } from 'date-fns'
import { NodeDetailResponse } from '../types'
import api from '../api/client'
import StatusBadge from '../components/StatusBadge'
import RewardChart from '../components/RewardChart'
import CommandPanel from '../components/CommandPanel'

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

  const { node, history } = data

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
              value={node.uptime_ratio != null ? `${node.uptime_ratio.toFixed(1)}%` : null}
            />
            <InfoRow label="Script Version" value={node.script_version} />
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

        {/* Control */}
        <div className="bg-white rounded-xl shadow-sm p-5">
          <h2 className="text-sm font-semibold text-gray-700 mb-4">Điều khiển node</h2>
          <CommandPanel nodeId={node.node_id} />
        </div>
      </main>
    </div>
  )
}
