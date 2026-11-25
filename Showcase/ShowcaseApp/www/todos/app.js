import { createApp } from '/_framework/vue.js'

const KEY = 'showcase-demo-key' // demo placeholder, same value as TodoServer.demoApiKey

createApp({
  data: () => ({ todos: [], title: '', status: '', ok: true }),
  mounted() { this.load() },
  methods: {
    async load() {
      this.todos = await (await fetch('/api/todos')).json()
    },
    async call(method, path, body, withKey) {
      const headers = { 'Content-Type': 'application/json' }
      if (withKey) headers['X-Api-Key'] = KEY
      const res = await fetch(path, { method, headers, body: body && JSON.stringify(body) })
      this.ok = res.ok
      this.status = `${method} ${path} -> ${res.status}`
      if (res.ok) await this.load()
    },
    add(withKey) {
      const id = Math.max(0, ...this.todos.map(t => t.id)) + 1
      return this.call('POST', '/api/todos', { id, title: this.title || 'Untitled', isDone: false }, withKey)
    },
    remove(id) { return this.call('DELETE', `/api/todos/${id}`, null, true) }
  }
}).mount('#app')
