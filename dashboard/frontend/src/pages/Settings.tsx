import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { ArrowLeft, Send } from 'lucide-react'
import api from '../api/client'

interface SettingsData {
  tg_critical: string
  tg_warning: string
  tg_info: string
  tg_stats: string
  alert_offline_minutes: number
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

export default function SettingsPage() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [form, setForm] = useState<SettingsData>({
    tg_critical: '', tg_warning: '', tg_info: '', tg_stats: '',
    alert_offline_minutes: 10,
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

        {/* Save */}
        <div className="flex justify-end">
          <button
            onClick={() => save.mutate()}
            disabled={save.isPending}
            className="px-6 py-2.5 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 disabled:opacity-50 transition-colors"
          >
            {saved ? '✓ Đã lưu' : save.isPending ? 'Đang lưu...' : 'Lưu cài đặt'}
          </button>
        </div>
      </main>
    </div>
  )
}
