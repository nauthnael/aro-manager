import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import Login from './pages/Login'
import Dashboard from './pages/Dashboard'
import NodeDetail from './pages/NodeDetail'
import AccountStats from './pages/AccountStats'
import Settings from './pages/Settings'
import ErrorStats from './pages/ErrorStats'
import ProxyStats from './pages/ProxyStats'
import RenewNodes from './pages/RenewNodes'

function PrivateRoute({ children }: { children: React.ReactNode }) {
  return localStorage.getItem('token') ? <>{children}</> : <Navigate to="/login" replace />
}

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/login" element={<Login />} />
        <Route path="/" element={<PrivateRoute><Dashboard /></PrivateRoute>} />
        <Route path="/nodes/:nodeId" element={<PrivateRoute><NodeDetail /></PrivateRoute>} />
        <Route path="/accounts" element={<PrivateRoute><AccountStats /></PrivateRoute>} />
        <Route path="/errors" element={<PrivateRoute><ErrorStats /></PrivateRoute>} />
        <Route path="/proxy-stats" element={<PrivateRoute><ProxyStats /></PrivateRoute>} />
        <Route path="/settings" element={<PrivateRoute><Settings /></PrivateRoute>} />
        <Route path="/renew" element={<PrivateRoute><RenewNodes /></PrivateRoute>} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  )
}
