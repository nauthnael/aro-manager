import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { useGoBack } from '../utils/navigation'
import { ArrowLeft, Check, Pencil, Plus, Send, Radio, Database, Download, Trash2, RefreshCw, X } from 'lucide-react'
import api from '../api/client'
import { TagOut } from '../types'
import TelegramHealthBanner from '../components/TelegramHealthBanner'

interface SettingsData {
  tg_critical: string
  tg_warning: string
  tg_info: string
  tg_stats: string
  alert_offline_minutes: number
  periodic_restart_min: number
  periodic_restart_max: number
  daily_report_enabled: boolean
  log_stale_restart_minutes: number
  node_tg_bot_token: string
  backup_enabled: boolean
  backup_interval_hours: number
  backup_retention_count: number
  duplicate_ip_alert_minutes: number
}

interface BackupFile {
  filename: string
  size: number
  created_at: string
}

interface DbStatus {
  db_size: string
  db_size_bytes: number
  pg_version: string
  host: string
  dbname: string
  counts: Record<string, number>
  table_sizes: { table: string; size: string }[]
  error?: string
}

function fmtBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function fmtDate(iso: string): string {
  const d = new Date(iso)
  return d.toLocaleString('vi-VN', { dateStyle: 'short', timeStyle: 'short' })
}

const TOPIC_LABELS: { key: keyof SettingsData; label: string; color: string }[] = [
  { key: 'tg_critical', label: 'Nghiêm trọng', color: 'text-red-600' },
  { key: 'tg_warning',  label: 'Chú ý',        color: 'text-yellow-600' },
  { key: 'tg_info',     label: 'Thông Báo',     color: 'text-blue-600' },
  { key: 'tg_stats',    label: 'Thống Kê',      color: 'text-green-600' },
]

function TopicInput({
  label,
  color,
  value,
  onChange,
  onTest,
  testing,
  testResult,
}: {
  label: string
  color: string
  value: string
  onChange: (v: string) => void
  onTest: () => void
  testing: boolean
  testResult: { ok: boolean; error: string | null } | null
}) {
  return (
    <div className="space-y-1.5">
      <label className={`text-sm font-medium ${color}`}>{label}</label>
      <div className="flex gap-2">
        <input
          type="text"
          value={value}
          onChange={e => onChange(e.target.value)}
          placeholder="chat_id:thread_id"
          className="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-blue-500"
        />
        <button
          onClick={onTest}
          disabled={testing || !value}
          className="flex items-center gap-1.5 px-3 py-2 text-sm bg-gray-100 text-gray-700 rounded-lg hover:bg-gray-200 disabled:opacity-40 transition-colors whitespace-nowrap"
        >
          <Send size={14} />
          Test
        </button>
      </div>
      {testResult && (
        <p className={`text-xs ${testResult.ok ? 'text-green-600' : 'text-red-600'}`}>
          {testResult.ok ? '✓ Gửi thành công' : `✗ ${testResult.error}`}
        </p>
      )}
    </div>
  )
}

const TAG_PALETTE = [
  '#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6',
  '#06b6d4', '#f97316', '#ec4899', '#14b8a6', '#6366f1',
  '#84cc16', '#a855f7',
]

function TagManager() {
  const qc = useQueryClient()
  const [newName, setNewName] = useState('')
  const [newColor, setNewColor] = useState(TAG_PALETTE[0])
  const [editId, setEditId] = useState<number | null>(null)
  const [editName, setEditName] = useState('')
  const [editColor, setEditColor] = useState('')

  const { data: tags = [] } = useQuery<TagOut[]>({
    queryKey: ['tags'],
    queryFn: () => api.get('/tags').then(r => r.data),
  })

  const createTag = useMutation({
    mutationFn: () => api.post('/tags', { name: newName.trim(), color: newColor }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['tags'] })
      setNewName('')
      const used = new Set(tags.map(t => t.color))
      const next = TAG_PALETTE.find(c => !used.has(c)) ?? TAG_PALETTE[0]
      setNewColor(next)
    },
  })

  const updateTag = useMutation({
    mutationFn: ({ id, name, color }: { id: number; name: string; color: string }) =>
      api.put(`/tags/${id}`, { name, color }),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['tags'] }); setEditId(null) },
  })

  const deleteTag = useMutation({
    mutationFn: (id: number) => api.delete(`/tags/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['tags'] }),
  })

  const startEdit = (t: TagOut) => { setEditId(t.id); setEditName(t.name); setEditColor(t.color) }

  return (
    <div className="bg-white rounded-xl shadow-sm p-5 space-y-4">
      <div>
        <h2 className="text-sm font-semibold text-gray-700">Quản lý Tags</h2>
        <p className="text-xs text-gray-400 mt-0.5">Tạo và quản lý tag để phân nhóm node.</p>
      </div>
      <div className="flex items-center gap-2 flex-wrap">
        <input type="text" placeholder="Tên tag mới..." value={newName}
          onChange={e => setNewName(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && newName.trim() && createTag.mutate()}
          className="flex-1 min-w-[140px] border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500" />
        <div className="flex items-center gap-1 flex-wrap">
          {TAG_PALETTE.map(c => (
            <button key={c} onClick={() => setNewColor(c)} style={{ backgroundColor: c }}
              className={`w-5 h-5 rounded-full border-2 transition-transform ${newColor === c ? 'border-gray-800 scale-110' : 'border-transparent'}`} />
          ))}
        </div>
        <button onClick={() => newName.trim() && createTag.mutate()}
          disabled={!newName.trim() || createTag.isPending}
          className="flex items-center gap-1 px-3 py-2 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700 disabled:opacity-50 transition-colors">
          <Plus size={14} /> Tạo
        </button>
      </div>
      {tags.length === 0 ? (
        <p className="text-sm text-gray-400 italic">Chưa có tag nào.</p>
      ) : (
        <div className="space-y-1.5">
          {tags.map(tag => (
            <div key={tag.id} className="flex items-center gap-2 py-1.5 px-2 rounded-lg hover:bg-gray-50">
              {editId === tag.id ? (
                <>
                  <div className="flex items-center gap-1 flex-wrap">
                    {TAG_PALETTE.map(c => (
                      <button key={c} onClick={() => setEditColor(c)} style={{ backgroundColor: c }}
                        className={`w-4 h-4 rounded-full border-2 transition-transform ${editColor === c ? 'border-gray-800 scale-110' : 'border-transparent'}`} />
                    ))}
                  </div>
                  <input autoFocus value={editName} onChange={e => setEditName(e.target.value)}
                    onKeyDown={e => {
                      if (e.key === 'Enter') updateTag.mutate({ id: tag.id, name: editName.trim(), color: editColor })
                      if (e.key === 'Escape') setEditId(null)
                    }}
                    className="flex-1 border border-gray-300 rounded px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500" />
                  <button onClick={() => updateTag.mutate({ id: tag.id, name: editName.trim(), color: editColor })}
                    disabled={!editName.trim()} className="p-1 text-green-600 hover:text-green-700 disabled:opacity-40">
                    <Check size={15} />
                  </button>
                  <button onClick={() => setEditId(null)} className="p-1 text-gray-400 hover:text-gray-600"><X size={15} /></button>
                </>
              ) : (
                <>
                  <span className="inline-block w-3 h-3 rounded-full flex-shrink-0" style={{ backgroundColor: tag.color }} />
                  <span className="flex-1 text-sm text-gray-700 font-medium">{tag.name}</span>
                  <span className="text-xs text-gray-400">{tag.node_count} node</span>
                  <button onClick={() => startEdit(tag)} className="p-1 text-gray-400 hover:text-gray-600 transition-colors"><Pencil size={13} /></button>
                  <button onClick={() => { if (!confirm(`Xóa tag "${tag.name}"? Tag sẽ bị gỡ khỏi ${tag.node_count} node.`)) return; deleteTag.mutate(tag.id) }}
                    className="p-1 text-gray-400 hover:text-red-500 transition-colors"><Trash2 size={13} /></button>
                </>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

export default function SettingsPage() {
  useEffect(() => { document.title = '💲 Cài đặt | ARO Dashboard' }, [])
  const navigate = useNavigate()
  const goBack = useGoBack()
  const qc = useQueryClient()
  const [form, setForm] = useState<SettingsData>({
    tg_critical: '', tg_warning: '', tg_info: '', tg_stats: '',
    alert_offline_minutes: 10,
    periodic_restart_min: 54,
    periodic_restart_max: 120,
    daily_report_enabled: true,
    log_stale_restart_minutes: 5,
    node_tg_bot_token: '',
    backup_enabled: false,
    backup_interval_hours: 24,
    backup_retention_count: 7,
    duplicate_ip_alert_minutes: 60,
  })
  const [testResults, setTestResults] = useState<Record<string, { ok: boolean; error: string | null } | null>>({})
  const [testingTopic, setTestingTopic] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [broadcastChatId, setBroadcastChatId] = useState('')
  const [broadcastToken, setBroadcastToken] = useState('')

  const { data, isLoading } = useQuery<SettingsData>({
    queryKey: ['settings'],
    queryFn: () => api.get('/settings').then(r => r.data),
  })

  useEffect(() => {
    if (data) setForm(data)
  }, [data])

  const save = useMutation({
    mutationFn: () => api.put('/settings', form),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['settings'] })
      setSaved(true)
      setTimeout(() => setSaved(false), 2000)
    },
  })

  const testTopic = async (topic: string) => {
    setTestingTopic(topic)
    setTestResults(prev => ({ ...prev, [topic]: null }))
    try {
      const r = await api.post('/settings/test', { topic })
      setTestResults(prev => ({ ...prev, [topic]: r.data }))
    } catch {
      setTestResults(prev => ({ ...prev, [topic]: { ok: false, error: 'Request thất bại' } }))
    } finally {
      setTestingTopic(null)
    }
  }

  const { data: dbStatus, refetch: refetchDbStatus } = useQuery<DbStatus>({
    queryKey: ['db-status'],
    queryFn: () => api.get('/settings/database/status').then(r => r.data),
    staleTime: 30_000,
  })

  const { data: backupFiles = [], refetch: refetchBackups } = useQuery<BackupFile[]>({
    queryKey: ['backups'],
    queryFn: () => api.get('/settings/database/backups').then(r => r.data),
    staleTime: 10_000,
  })

  const createBackupMut = useMutation({
    mutationFn: () => api.post('/settings/database/backup').then(r => r.data),
    onSuccess: () => refetchBackups(),
    onError: (err: any) => alert(err?.response?.data?.detail ?? 'Lỗi khi tạo backup.'),
  })

  const deleteBackupMut = useMutation({
    mutationFn: (filename: string) => api.delete(`/settings/database/backups/${encodeURIComponent(filename)}`),
    onSuccess: () => refetchBackups(),
  })

  const downloadBackup = async (filename: string) => {
    try {
      const resp = await api.get(`/settings/database/backups/${encodeURIComponent(filename)}/download`, { responseType: 'blob' })
      const url = URL.createObjectURL(resp.data)
      const a = document.createElement('a')
      a.href = url
      a.download = filename
      a.click()
      URL.revokeObjectURL(url)
    } catch {
      alert('Lỗi khi tải file backup.')
    }
  }

  const broadcastChatIdMut = useMutation({
    mutationFn: () => api.post('/settings/broadcast-tg-chatid', { tg_chat_id: broadcastChatId }),
    onSuccess: (r) => alert(`Đã gửi lệnh đổi Chat ID tới ${r.data.sent} node.`),
  })

  const broadcastTokenMut = useMutation({
    mutationFn: () => api.post('/settings/broadcast-tg-token', { tg_bot_token: broadcastToken }),
    onSuccess: (r) => alert(`Đã gửi lệnh đổi Bot Token tới ${r.data.sent} node.`),
  })

  const setField = (key: keyof SettingsData) => (v: string) =>
    setForm(f => ({ ...f, [key]: v }))

  const topicKey = (label: string) =>
    ({ 'Nghiêm trọng': 'critical', 'Chú ý': 'warning', 'Thông Báo': 'info', 'Thống Kê': 'stats' }[label] ?? label)

  if (isLoading) {
    return (
      <div className="min-h-screen bg-gray-100 flex items-center justify-center text-gray-400">
        Đang tải...
      </div>
    )
  }

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-2xl mx-auto px-4 py-3 flex items-center gap-3">
          <button onClick={goBack} className="p-1 text-gray-500 hover:text-gray-800">
            <ArrowLeft size={18} />
          </button>
          <h1 className="text-lg font-bold text-gray-800 flex-1">Cài đặt</h1>
        </div>
      </header>

      <main className="max-w-2xl mx-auto px-4 py-6 space-y-6">
        <TelegramHealthBanner />

        {/* Node bot token */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-3">
          <div>
            <h2 className="text-sm font-semibold text-gray-700">Node Bot Token</h2>
            <p className="text-xs text-gray-400 mt-0.5">
              Bot token đang dùng trên các node (để theo dõi health trên dashboard). Không dùng để gửi tin nhắn từ dashboard.
            </p>
          </div>
          <input
            type="text"
            value={form.node_tg_bot_token}
            onChange={e => setForm(f => ({ ...f, node_tg_bot_token: e.target.value }))}
            placeholder="123456789:AABBCCDDEEFFaabbccddeeff..."
            className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-blue-500"
          />
        </div>

        {/* Telegram topics */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-5">
          <div>
            <h2 className="text-sm font-semibold text-gray-700">Telegram Topics (Dashboard Bot)</h2>
            <p className="text-xs text-gray-400 mt-0.5">
              Định dạng: <code className="font-mono bg-gray-100 px-1 rounded">chat_id:thread_id</code>
            </p>
          </div>

          {TOPIC_LABELS.map(({ key, label, color }) => {
            const tk = topicKey(label)
            return (
              <TopicInput
                key={key}
                label={label}
                color={color}
                value={form[key] as string}
                onChange={setField(key)}
                onTest={() => testTopic(tk)}
                testing={testingTopic === tk}
                testResult={testResults[tk] ?? null}
              />
            )
          })}
        </div>

        {/* Alert threshold */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-3">
          <h2 className="text-sm font-semibold text-gray-700">Cảnh báo Offline</h2>
          <div className="flex items-center gap-3">
            <label className="text-sm text-gray-600 whitespace-nowrap">Gửi alert sau</label>
            <input
              type="number"
              min={1}
              max={1440}
              value={form.alert_offline_minutes}
              onChange={e => setForm(f => ({ ...f, alert_offline_minutes: parseInt(e.target.value) || 10 }))}
              className="w-24 border border-gray-300 rounded-lg px-3 py-2 text-sm text-center focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
            <label className="text-sm text-gray-600">phút offline liên tục</label>
          </div>
          <p className="text-xs text-gray-400">
            Alert gửi vào topic <span className="text-red-500 font-medium">Nghiêm trọng</span>. Mỗi lần offline chỉ gửi 1 lần.
          </p>
        </div>

        {/* Duplicate IP alert */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-3">
          <h2 className="text-sm font-semibold text-gray-700">Cảnh báo Trùng Exit IP</h2>
          <div className="flex items-center gap-3">
            <label className="text-sm text-gray-600 whitespace-nowrap">Gửi lại sau mỗi</label>
            <input
              type="number"
              min={1}
              max={1440}
              value={form.duplicate_ip_alert_minutes}
              onChange={e => setForm(f => ({ ...f, duplicate_ip_alert_minutes: parseInt(e.target.value) || 60 }))}
              className="w-24 border border-gray-300 rounded-lg px-3 py-2 text-sm text-center focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
            <label className="text-sm text-gray-600">phút (nếu vẫn còn trùng)</label>
          </div>
          <p className="text-xs text-gray-400">
            Alert gửi vào topic <span className="text-red-500 font-medium">Nghiêm trọng</span>. Kiểm tra mỗi phút, chỉ gửi khi đủ khoảng thời gian cấu hình và còn node bị trùng IP.
          </p>
        </div>

        {/* Periodic restart */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-4">
          <div>
            <h2 className="text-sm font-semibold text-gray-700">Tự khởi động lại ARO định kỳ</h2>
            <p className="text-xs text-gray-400 mt-0.5">
              Watchdog sẽ restart ARO app ngẫu nhiên trong khoảng thời gian này. Áp dụng cho toàn bộ node sau chu kỳ báo cáo tiếp theo (~60s).
            </p>
          </div>
          <div className="flex items-center gap-3 flex-wrap">
            <label className="text-sm text-gray-600 whitespace-nowrap">Mỗi</label>
            <input
              type="number"
              min={1}
              max={1440}
              value={form.periodic_restart_min}
              onChange={e => setForm(f => ({ ...f, periodic_restart_min: parseInt(e.target.value) || 54 }))}
              className="w-24 border border-gray-300 rounded-lg px-3 py-2 text-sm text-center focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
            <label className="text-sm text-gray-600 whitespace-nowrap">đến</label>
            <input
              type="number"
              min={1}
              max={1440}
              value={form.periodic_restart_max}
              onChange={e => setForm(f => ({ ...f, periodic_restart_max: parseInt(e.target.value) || 120 }))}
              className="w-24 border border-gray-300 rounded-lg px-3 py-2 text-sm text-center focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
            <label className="text-sm text-gray-600 whitespace-nowrap">phút (ngẫu nhiên)</label>
          </div>
          {form.periodic_restart_min >= form.periodic_restart_max && (
            <p className="text-xs text-red-500">Min phải nhỏ hơn Max.</p>
          )}
        </div>

        {/* Log stale restart */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-3">
          <div>
            <h2 className="text-sm font-semibold text-gray-700">Log Stale Restart</h2>
            <p className="text-xs text-gray-400 mt-0.5">
              Khởi động lại ARO nếu log không cập nhật sau N phút (ARO bị đóng băng). Có thể override per-node trên trang chi tiết node.
            </p>
          </div>
          <div className="flex items-center gap-3">
            <label className="text-sm text-gray-600 whitespace-nowrap">Restart sau</label>
            <input
              type="number"
              min={1}
              max={60}
              value={form.log_stale_restart_minutes}
              onChange={e => setForm(f => ({ ...f, log_stale_restart_minutes: Math.max(1, Math.min(60, parseInt(e.target.value) || 5)) }))}
              className="w-20 border border-gray-300 rounded-lg px-3 py-2 text-sm text-center focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
            <label className="text-sm text-gray-600 whitespace-nowrap">phút stale (1–60)</label>
          </div>
        </div>

        {/* Daily report */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-3">
          <h2 className="text-sm font-semibold text-gray-700">Báo cáo hằng ngày</h2>
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm text-gray-600">Gửi báo cáo tự động lúc 7:00 sáng</p>
              <p className="text-xs text-gray-400 mt-0.5">Áp dụng cho toàn bộ node sau chu kỳ báo cáo tiếp theo (~60s).</p>
            </div>
            <button
              type="button"
              onClick={() => setForm(f => ({ ...f, daily_report_enabled: !f.daily_report_enabled }))}
              className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 ${
                form.daily_report_enabled ? 'bg-blue-600' : 'bg-gray-300'
              }`}
            >
              <span
                className={`inline-block h-4 w-4 transform rounded-full bg-white shadow transition-transform ${
                  form.daily_report_enabled ? 'translate-x-6' : 'translate-x-1'
                }`}
              />
            </button>
          </div>
        </div>

        {/* Broadcast TG settings to all nodes */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-4">
          <div>
            <h2 className="text-sm font-semibold text-gray-700 flex items-center gap-1.5">
              <Radio size={14} />
              Phát lệnh đến tất cả Node
            </h2>
            <p className="text-xs text-gray-400 mt-0.5">
              Gửi lệnh thay đổi cấu hình Telegram đến tất cả node đang được quản lý. Node sẽ nhận và áp dụng khi báo cáo tiếp theo (~60s).
            </p>
          </div>

          {/* Broadcast Chat ID */}
          <div className="space-y-1.5">
            <label className="text-sm font-medium text-gray-600">Đổi TG_CHAT_ID cho tất cả node</label>
            <div className="flex gap-2">
              <input
                type="text"
                value={broadcastChatId}
                onChange={e => setBroadcastChatId(e.target.value)}
                placeholder="chat_id:thread_id mới"
                className="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-blue-500"
              />
              <button
                onClick={() => {
                  if (!broadcastChatId.trim()) return
                  if (confirm(`Gửi TG_CHAT_ID mới (${broadcastChatId}) đến TẤT CẢ node?`))
                    broadcastChatIdMut.mutate()
                }}
                disabled={broadcastChatIdMut.isPending || !broadcastChatId.trim()}
                className="flex items-center gap-1.5 px-3 py-2 text-sm bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-40 transition-colors whitespace-nowrap"
              >
                <Radio size={14} />
                Phát lệnh
              </button>
            </div>
          </div>

          {/* Broadcast Bot Token */}
          <div className="space-y-1.5">
            <label className="text-sm font-medium text-gray-600">Đổi TG_BOT_TOKEN cho tất cả node</label>
            <div className="flex gap-2">
              <input
                type="text"
                value={broadcastToken}
                onChange={e => setBroadcastToken(e.target.value)}
                placeholder="Bot token mới (123456:AABB...)"
                className="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-blue-500"
              />
              <button
                onClick={() => {
                  if (!broadcastToken.trim()) return
                  if (confirm('Gửi TG_BOT_TOKEN mới đến TẤT CẢ node?'))
                    broadcastTokenMut.mutate()
                }}
                disabled={broadcastTokenMut.isPending || !broadcastToken.trim()}
                className="flex items-center gap-1.5 px-3 py-2 text-sm bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-40 transition-colors whitespace-nowrap"
              >
                <Radio size={14} />
                Phát lệnh
              </button>
            </div>
          </div>
        </div>

        {/* Database status */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-4">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-semibold text-gray-700 flex items-center gap-1.5">
              <Database size={14} />
              Trạng thái Database
            </h2>
            <button onClick={() => refetchDbStatus()} className="p-1 text-gray-400 hover:text-gray-600" title="Làm mới">
              <RefreshCw size={14} />
            </button>
          </div>
          {dbStatus?.error ? (
            <p className="text-xs text-red-500">{dbStatus.error}</p>
          ) : dbStatus ? (
            <div className="space-y-3">
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
                {[
                  { label: 'Kích thước DB', value: dbStatus.db_size },
                  { label: 'PostgreSQL', value: dbStatus.pg_version },
                  { label: 'Host', value: dbStatus.host },
                  { label: 'Database', value: dbStatus.dbname },
                  { label: 'Nodes', value: `${dbStatus.counts.nodes ?? 0}` },
                  { label: 'History records', value: `${(dbStatus.counts.node_history ?? 0).toLocaleString()}` },
                ].map(({ label, value }) => (
                  <div key={label}>
                    <p className="text-xs text-gray-400">{label}</p>
                    <p className="text-sm font-medium text-gray-700 font-mono">{value}</p>
                  </div>
                ))}
              </div>
              <div>
                <p className="text-xs text-gray-400 mb-1.5">Dung lượng theo bảng</p>
                <div className="space-y-1">
                  {dbStatus.table_sizes.map(t => (
                    <div key={t.table} className="flex justify-between text-xs">
                      <span className="text-gray-600 font-mono">{t.table}</span>
                      <span className="text-gray-500">{t.size}</span>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          ) : (
            <p className="text-xs text-gray-400">Đang tải...</p>
          )}
        </div>

        {/* Backup */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-4">
          <div className="flex items-center justify-between">
            <div>
              <h2 className="text-sm font-semibold text-gray-700">Backup Database</h2>
              <p className="text-xs text-gray-400 mt-0.5">File SQL lưu tại <code className="font-mono bg-gray-100 px-1 rounded">/app/backups/</code> trên server.</p>
            </div>
            <button
              onClick={() => createBackupMut.mutate()}
              disabled={createBackupMut.isPending}
              className="flex items-center gap-1.5 px-3 py-1.5 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700 disabled:opacity-50 transition-colors whitespace-nowrap"
            >
              <Database size={14} className={createBackupMut.isPending ? 'animate-pulse' : ''} />
              {createBackupMut.isPending ? 'Đang tạo...' : 'Tạo backup ngay'}
            </button>
          </div>

          {backupFiles.length === 0 ? (
            <p className="text-xs text-gray-400">Chưa có file backup nào.</p>
          ) : (
            <div className="divide-y divide-gray-100">
              {backupFiles.map(f => (
                <div key={f.filename} className="flex items-center justify-between py-2 gap-2">
                  <div className="min-w-0">
                    <p className="text-xs font-mono text-gray-700 truncate">{f.filename}</p>
                    <p className="text-xs text-gray-400">{fmtDate(f.created_at)} · {fmtBytes(f.size)}</p>
                  </div>
                  <div className="flex items-center gap-1 shrink-0">
                    <button
                      onClick={() => downloadBackup(f.filename)}
                      className="p-1.5 text-blue-600 hover:bg-blue-50 rounded-lg transition-colors"
                      title="Tải xuống"
                    >
                      <Download size={14} />
                    </button>
                    <button
                      onClick={() => {
                        if (confirm(`Xoá backup "${f.filename}"?`)) deleteBackupMut.mutate(f.filename)
                      }}
                      className="p-1.5 text-gray-400 hover:text-red-600 hover:bg-red-50 rounded-lg transition-colors"
                      title="Xoá"
                    >
                      <Trash2 size={14} />
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Scheduled backup config */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-4">
          <div>
            <h2 className="text-sm font-semibold text-gray-700">Backup định kỳ</h2>
            <p className="text-xs text-gray-400 mt-0.5">Tự động tạo backup theo lịch. Kiểm tra mỗi giờ.</p>
          </div>
          <div className="flex items-center justify-between">
            <span className="text-sm text-gray-600">Bật backup tự động</span>
            <button
              type="button"
              onClick={() => setForm(f => ({ ...f, backup_enabled: !f.backup_enabled }))}
              className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 ${form.backup_enabled ? 'bg-blue-600' : 'bg-gray-300'}`}
            >
              <span className={`inline-block h-4 w-4 transform rounded-full bg-white shadow transition-transform ${form.backup_enabled ? 'translate-x-6' : 'translate-x-1'}`} />
            </button>
          </div>
          {form.backup_enabled && (
            <div className="space-y-3 pt-1">
              <div className="flex items-center gap-3">
                <label className="text-sm text-gray-600 whitespace-nowrap">Mỗi</label>
                <input
                  type="number" min={1} max={720}
                  value={form.backup_interval_hours}
                  onChange={e => setForm(f => ({ ...f, backup_interval_hours: Math.max(1, parseInt(e.target.value) || 24) }))}
                  className="w-20 border border-gray-300 rounded-lg px-3 py-2 text-sm text-center focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
                <label className="text-sm text-gray-600 whitespace-nowrap">giờ</label>
              </div>
              <div className="flex items-center gap-3">
                <label className="text-sm text-gray-600 whitespace-nowrap">Giữ lại</label>
                <input
                  type="number" min={1} max={30}
                  value={form.backup_retention_count}
                  onChange={e => setForm(f => ({ ...f, backup_retention_count: Math.max(1, parseInt(e.target.value) || 7) }))}
                  className="w-20 border border-gray-300 rounded-lg px-3 py-2 text-sm text-center focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
                <label className="text-sm text-gray-600 whitespace-nowrap">bản gần nhất (tự xoá cũ hơn)</label>
              </div>
            </div>
          )}
        </div>

        {/* Tag Manager */}
        <TagManager />

        {/* Save */}
        <div className="flex justify-end">
          <button
            onClick={() => save.mutate()}
            disabled={save.isPending || form.periodic_restart_min >= form.periodic_restart_max}
            className="px-6 py-2.5 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 disabled:opacity-50 transition-colors"
          >
            {saved ? '✓ Đã lưu' : save.isPending ? 'Đang lưu...' : 'Lưu cài đặt'}
          </button>
        </div>
      </main>
    </div>
  )
}
