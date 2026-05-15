import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { ArrowLeft, Check, Pencil, Plus, Send, Trash2, X } from 'lucide-react'
import api from '../api/client'
import { TagOut } from '../types'

interface SettingsData {
  tg_critical: string
  tg_warning: string
  tg_info: string
  tg_stats: string
  alert_offline_minutes: number
  periodic_restart_min: number
  periodic_restart_max: number
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

// ── Bảng màu tự động ──────────────────────────────────────────────────────
const TAG_PALETTE = [
  '#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6',
  '#06b6d4', '#f97316', '#ec4899', '#14b8a6', '#6366f1',
  '#84cc16', '#a855f7',
]

// ── Component quản lý Tags ─────────────────────────────────────────────────
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
      // Advance color to next unused
      const used = new Set(tags.map(t => t.color))
      const next = TAG_PALETTE.find(c => !used.has(c)) ?? TAG_PALETTE[0]
      setNewColor(next)
    },
  })

  const updateTag = useMutation({
    mutationFn: ({ id, name, color }: { id: number; name: string; color: string }) =>
      api.put(`/tags/${id}`, { name, color }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['tags'] })
      setEditId(null)
    },
  })

  const deleteTag = useMutation({
    mutationFn: (id: number) => api.delete(`/tags/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['tags'] }),
  })

  const startEdit = (t: TagOut) => {
    setEditId(t.id)
    setEditName(t.name)
    setEditColor(t.color)
  }

  return (
    <div className="bg-white rounded-xl shadow-sm p-5 space-y-4">
      <div>
        <h2 className="text-sm font-semibold text-gray-700">Quản lý Tags</h2>
        <p className="text-xs text-gray-400 mt-0.5">Tạo và quản lý tag để phân nhóm node.</p>
      </div>

      {/* Tạo tag mới */}
      <div className="flex items-center gap-2 flex-wrap">
        <input
          type="text"
          placeholder="Tên tag mới..."
          value={newName}
          onChange={e => setNewName(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && newName.trim() && createTag.mutate()}
          className="flex-1 min-w-[140px] border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
        />
        {/* Bảng màu */}
        <div className="flex items-center gap-1 flex-wrap">
          {TAG_PALETTE.map(c => (
            <button
              key={c}
              onClick={() => setNewColor(c)}
              style={{ backgroundColor: c }}
              className={`w-5 h-5 rounded-full border-2 transition-transform ${newColor === c ? 'border-gray-800 scale-110' : 'border-transparent'}`}
            />
          ))}
        </div>
        <button
          onClick={() => newName.trim() && createTag.mutate()}
          disabled={!newName.trim() || createTag.isPending}
          className="flex items-center gap-1 px-3 py-2 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700 disabled:opacity-50 transition-colors"
        >
          <Plus size={14} /> Tạo
        </button>
      </div>

      {/* Danh sách tags */}
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
                      <button
                        key={c}
                        onClick={() => setEditColor(c)}
                        style={{ backgroundColor: c }}
                        className={`w-4 h-4 rounded-full border-2 transition-transform ${editColor === c ? 'border-gray-800 scale-110' : 'border-transparent'}`}
                      />
                    ))}
                  </div>
                  <input
                    autoFocus
                    value={editName}
                    onChange={e => setEditName(e.target.value)}
                    onKeyDown={e => {
                      if (e.key === 'Enter') updateTag.mutate({ id: tag.id, name: editName.trim(), color: editColor })
                      if (e.key === 'Escape') setEditId(null)
                    }}
                    className="flex-1 border border-gray-300 rounded px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  />
                  <button
                    onClick={() => updateTag.mutate({ id: tag.id, name: editName.trim(), color: editColor })}
                    disabled={!editName.trim()}
                    className="p-1 text-green-600 hover:text-green-700 disabled:opacity-40"
                  >
                    <Check size={15} />
                  </button>
                  <button onClick={() => setEditId(null)} className="p-1 text-gray-400 hover:text-gray-600">
                    <X size={15} />
                  </button>
                </>
              ) : (
                <>
                  <span
                    className="inline-block w-3 h-3 rounded-full flex-shrink-0"
                    style={{ backgroundColor: tag.color }}
                  />
                  <span className="flex-1 text-sm text-gray-700 font-medium">{tag.name}</span>
                  <span className="text-xs text-gray-400">{tag.node_count} node</span>
                  <button onClick={() => startEdit(tag)} className="p-1 text-gray-400 hover:text-gray-600 transition-colors">
                    <Pencil size={13} />
                  </button>
                  <button
                    onClick={() => {
                      if (!confirm(`Xóa tag "${tag.name}"? Tag sẽ bị gỡ khỏi ${tag.node_count} node.`)) return
                      deleteTag.mutate(tag.id)
                    }}
                    className="p-1 text-gray-400 hover:text-red-500 transition-colors"
                  >
                    <Trash2 size={13} />
                  </button>
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
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [form, setForm] = useState<SettingsData>({
    tg_critical: '', tg_warning: '', tg_info: '', tg_stats: '',
    alert_offline_minutes: 10,
    periodic_restart_min: 54,
    periodic_restart_max: 120,
  })
  const [testResults, setTestResults] = useState<Record<string, { ok: boolean; error: string | null } | null>>({})
  const [testingTopic, setTestingTopic] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)

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
          <button onClick={() => navigate('/')} className="p-1 text-gray-500 hover:text-gray-800">
            <ArrowLeft size={18} />
          </button>
          <h1 className="text-lg font-bold text-gray-800 flex-1">Cài đặt</h1>
        </div>
      </header>

      <main className="max-w-2xl mx-auto px-4 py-6 space-y-6">
        {/* Telegram topics */}
        <div className="bg-white rounded-xl shadow-sm p-5 space-y-5">
          <div>
            <h2 className="text-sm font-semibold text-gray-700">Telegram Topics</h2>
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

        {/* Tags */}
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
