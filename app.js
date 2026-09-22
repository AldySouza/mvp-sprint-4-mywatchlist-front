// MyWatchList frontend logic.
//
// Both base URLs below are browser-reachable hosts, not Docker service names —
// this script runs in the user's browser, not inside the Nginx container, so
// container-to-container DNS names (e.g. "mywatchlist-api") would not resolve
// here.
const API_BASE_URL = "http://localhost:8000";
const TVMAZE_BASE_URL = "https://api.tvmaze.com";

/**
 * Thin fetch wrapper: throws a plain Error with a user-friendly message on
 * network failure or a non-2xx response, otherwise resolves parsed JSON
 * (or null for 204 No Content).
 */
async function apiFetch(url, options) {
  let response;
  try {
    response = await fetch(url, options);
  } catch (err) {
    throw new Error("Não foi possível conectar. Verifique sua conexão e tente novamente.");
  }
  if (!response.ok) {
    let detail = "";
    try {
      const body = await response.json();
      detail = body.detail ? ` (${JSON.stringify(body.detail)})` : "";
    } catch (_) {
      // resposta sem corpo JSON, ignora
    }
    throw new Error(`Erro ${response.status}${detail}`);
  }
  if (response.status === 204) {
    return null;
  }
  return response.json();
}

let toastInstance = null;

/** Shows a Bootstrap toast with the given message. variant: "success" | "danger". */
function showToast(message, variant = "success") {
  const toastEl = document.getElementById("toast");
  const toastBody = document.getElementById("toast-body");
  toastEl.classList.remove("text-bg-success", "text-bg-danger");
  toastEl.classList.add(variant === "success" ? "text-bg-success" : "text-bg-danger");
  toastBody.textContent = message;
  if (!toastInstance) {
    toastInstance = new bootstrap.Toast(toastEl, { delay: 4000 });
  }
  toastInstance.show();
}

const PLACEHOLDER_IMAGE =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="210" height="295" viewBox="0 0 210 295">' +
      '<rect width="210" height="295" fill="#1d212c"/>' +
      '<text x="105" y="150" font-family="sans-serif" font-size="16" fill="#6b7282" text-anchor="middle">sem imagem</text>' +
      "</svg>"
  );

function genreBadges(genres) {
  if (!genres || genres.length === 0) {
    return '<span class="genre-chip genre-chip-empty">sem gênero</span>';
  }
  return genres
    .slice(0, 3)
    .map((g) => `<span class="genre-chip">${escapeHtml(g)}</span>`)
    .join("");
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

// ---------------------------------------------------------------------------
// Busca de séries na TVMaze
// ---------------------------------------------------------------------------

const searchInput = document.getElementById("search-input");
const searchResultsEl = document.getElementById("search-results");
const searchStatusEl = document.getElementById("search-status");

let searchDebounceTimer = null;

searchInput.addEventListener("input", () => {
  clearTimeout(searchDebounceTimer);
  const query = searchInput.value.trim();
  if (!query) {
    searchResultsEl.innerHTML = "";
    hideStatus(searchStatusEl);
    return;
  }
  // 300ms debounce — avoids one request per keystroke.
  searchDebounceTimer = setTimeout(() => runSearch(query), 300);
});

function showStatus(el, message) {
  el.textContent = message;
  el.hidden = false;
}

function hideStatus(el) {
  el.hidden = true;
  el.textContent = "";
}

function skeletonCards(count) {
  return Array.from(
    { length: count },
    () => `
    <div class="col">
      <div class="show-card is-loading" aria-hidden="true">
        <div class="poster skeleton"></div>
        <div class="show-info">
          <div class="skeleton skeleton-line"></div>
          <div class="skeleton skeleton-line short"></div>
        </div>
      </div>
    </div>`
  ).join("");
}

async function runSearch(query) {
  hideStatus(searchStatusEl);
  searchResultsEl.innerHTML = skeletonCards(5);
  let results;
  try {
    results = await apiFetch(
      `${TVMAZE_BASE_URL}/search/shows?q=${encodeURIComponent(query)}`
    );
  } catch (err) {
    searchResultsEl.innerHTML = "";
    showStatus(searchStatusEl, "Busca indisponível no momento. Tente novamente em instantes.");
    return;
  }
  // Uma resposta antiga não deve sobrescrever a busca que o usuário digitou depois.
  if (query !== searchInput.value.trim()) return;
  if (!results || results.length === 0) {
    searchResultsEl.innerHTML = "";
    showStatus(searchStatusEl, `Nenhum resultado para “${query}”.`);
    return;
  }
  showStatus(
    searchStatusEl,
    `${results.length} ${results.length === 1 ? "resultado" : "resultados"} para “${query}”`
  );
  searchResultsEl.innerHTML = results.map((r) => renderSearchCard(r.show)).join("");
}

// ---------------------------------------------------------------------------
// Adicionar resultado da busca aos favoritos (POST /favoritos)
// ---------------------------------------------------------------------------

const addModalEl = document.getElementById("add-modal");
const addModal = new bootstrap.Modal(addModalEl);
const addForm = document.getElementById("add-form");
let pendingShow = null;

searchResultsEl.addEventListener("click", (event) => {
  const btn = event.target.closest(".add-favorite-btn");
  if (!btn) return;
  pendingShow = {
    external_id: Number(btn.dataset.showId),
    name: btn.dataset.showName,
    genres: btn.dataset.showGenres ? btn.dataset.showGenres.split(",") : [],
    image_url: btn.dataset.showImage || null,
  };
  document.getElementById("add-show-name").textContent = pendingShow.name;
  addForm.reset();
  addModal.show();
});

addForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!pendingShow) return;
  const rating = Number(document.getElementById("add-rating").value);
  const comment = document.getElementById("add-comment").value.trim() || null;
  try {
    await apiFetch(`${API_BASE_URL}/favoritos`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...pendingShow, rating, comment }),
    });
    addModal.hide();
    showToast(`"${pendingShow.name}" adicionado aos favoritos!`, "success");
    pendingShow = null;
    loadFavoritos();
  } catch (err) {
    showToast(`Não foi possível salvar: ${err.message}`, "danger");
  }
});

// ---------------------------------------------------------------------------
// Listar, ordenar e filtrar favoritos (GET /favoritos)
// ---------------------------------------------------------------------------

const favoritesListEl = document.getElementById("favorites-list");
const favoritesStatusEl = document.getElementById("favorites-status");
const genreFilterEl = document.getElementById("genre-filter");
const sortByRatingEl = document.getElementById("sort-by-rating");

let knownGenres = new Set();
let favoritosById = {};

async function loadFavoritos() {
  const params = new URLSearchParams();
  if (sortByRatingEl.checked) params.set("sort_by", "rating");
  if (genreFilterEl.value) params.set("genre", genreFilterEl.value);

  // O painel reflete a lista inteira, independente do filtro/ordenação.
  loadEstatisticas();

  let favoritos;
  try {
    favoritos = await apiFetch(`${API_BASE_URL}/favoritos?${params.toString()}`);
  } catch (err) {
    favoritesListEl.innerHTML = "";
    showStatus(favoritesStatusEl, `Não foi possível carregar seus favoritos: ${err.message}`);
    return;
  }

  updateGenreFilterOptions(favoritos);

  if (favoritos.length === 0) {
    favoritesListEl.innerHTML = "";
    showStatus(
      favoritesStatusEl,
      genreFilterEl.value
        ? "Nenhum favorito com esse gênero."
        : "Você ainda não tem favoritos. Busque uma série acima e adicione uma!"
    );
    return;
  }

  hideStatus(favoritesStatusEl);
  favoritosById = Object.fromEntries(favoritos.map((f) => [f.id, f]));
  favoritesListEl.innerHTML = favoritos.map(renderFavoritoCard).join("");
}

function updateGenreFilterOptions(favoritos) {
  const currentSelection = genreFilterEl.value;
  const allGenres = new Set();
  favoritos.forEach((f) => f.genres.forEach((g) => allGenres.add(g)));
  // Mantém gêneros já vistos anteriormente para não "sumir" a opção selecionada
  // caso o filtro atual já tenha reduzido a lista a zero itens desse gênero.
  allGenres.forEach((g) => knownGenres.add(g));

  genreFilterEl.innerHTML =
    '<option value="">Todos os gêneros</option>' +
    [...knownGenres]
      .sort((a, b) => a.localeCompare(b))
      .map((g) => `<option value="${escapeHtml(g)}">${escapeHtml(g)}</option>`)
      .join("");
  genreFilterEl.value = currentSelection;
}

function renderFavoritoCard(favorito) {
  const image = favorito.image_url;
  const name = escapeHtml(favorito.name);
  return `
    <div class="col">
      <article class="show-card">
        <div class="poster">
          <img src="${image || PLACEHOLDER_IMAGE}" alt="Capa de ${name}" loading="lazy">
          <span class="rating-badge" aria-label="Nota ${favorito.rating} de 5"><i class="bi bi-star-fill"></i> ${favorito.rating}</span>
        </div>
        <div class="show-info">
          <h3 class="show-title" title="${name}">${name}</h3>
          <div class="genre-chips">${genreBadges(favorito.genres)}</div>
          <p class="stars" aria-hidden="true">${"★".repeat(favorito.rating)}<span class="stars-empty">${"★".repeat(5 - favorito.rating)}</span></p>
          ${favorito.comment ? `<p class="show-comment">“${escapeHtml(favorito.comment)}”</p>` : ""}
          <div class="card-actions">
            <button type="button" class="btn btn-sm btn-ghost edit-favorite-btn" data-id="${favorito.id}"><i class="bi bi-pencil"></i> Editar</button>
            <button type="button" class="btn btn-sm btn-ghost btn-ghost-danger delete-favorite-btn" data-id="${favorito.id}" aria-label="Remover ${name}"><i class="bi bi-trash3"></i></button>
          </div>
        </div>
      </article>
    </div>
  `;
}

// ---------------------------------------------------------------------------
// Painel — estatísticas da lista (GET /favoritos/estatisticas)
// ---------------------------------------------------------------------------

const MAX_GENEROS_NO_GRAFICO = 8;

async function loadEstatisticas() {
  let stats;
  try {
    stats = await apiFetch(`${API_BASE_URL}/favoritos/estatisticas`);
  } catch (err) {
    return; // a lista de favoritos já mostra o erro de conexão
  }
  document.getElementById("stat-total").textContent = stats.total;
  document.getElementById("stat-media").textContent =
    stats.media_notas == null ? "–" : stats.media_notas.toFixed(1).replace(".", ",");

  const notas = [5, 4, 3, 2, 1].map((n) => ({
    label: `${n} ★`,
    title: `Nota ${n}`,
    value: stats.por_nota[n] || 0,
  }));
  renderBarChart(document.getElementById("chart-notas"), notas);

  // Gêneros além do limite são somados em "Outros" para o gráfico não crescer sem fim.
  const generos = stats.por_genero.slice(0, MAX_GENEROS_NO_GRAFICO).map((g) => ({
    label: g.genero,
    title: g.genero,
    value: g.total,
  }));
  const outros = stats.por_genero
    .slice(MAX_GENEROS_NO_GRAFICO)
    .reduce((soma, g) => soma + g.total, 0);
  if (outros > 0) generos.push({ label: "Outros", title: "Outros gêneros", value: outros });
  renderBarChart(document.getElementById("chart-generos"), generos);
}

function renderBarChart(container, rows) {
  if (rows.length === 0 || rows.every((r) => r.value === 0)) {
    container.innerHTML = '<p class="text-muted small mb-0">Sem dados ainda.</p>';
    return;
  }
  const max = Math.max(...rows.map((r) => r.value));
  container.innerHTML = rows
    .map((r) => {
      const plural = r.value === 1 ? "série" : "séries";
      return `
        <div class="bar-row" role="listitem" title="${escapeHtml(r.title)}: ${r.value} ${plural}">
          <span class="bar-label">${escapeHtml(r.label)}</span>
          <div class="bar-track"><div class="bar-fill${r.value === 0 ? " is-empty" : ""}" style="width:${(r.value / max) * 100}%"></div></div>
          <span class="bar-value">${r.value}</span>
        </div>`;
    })
    .join("");
}

sortByRatingEl.addEventListener("change", loadFavoritos);
genreFilterEl.addEventListener("change", loadFavoritos);

loadFavoritos();

// ---------------------------------------------------------------------------
// Editar nota/comentário de um favorito (PUT /favoritos/{id})
// ---------------------------------------------------------------------------

const editModalEl = document.getElementById("edit-modal");
const editModal = new bootstrap.Modal(editModalEl);
const editForm = document.getElementById("edit-form");

favoritesListEl.addEventListener("click", (event) => {
  const btn = event.target.closest(".edit-favorite-btn");
  if (!btn) return;
  const favorito = favoritosById[btn.dataset.id];
  if (!favorito) return;
  document.getElementById("edit-id").value = favorito.id;
  document.getElementById("edit-show-name").textContent = favorito.name;
  document.getElementById("edit-rating").value = favorito.rating;
  document.getElementById("edit-comment").value = favorito.comment || "";
  editModal.show();
});

editForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const id = document.getElementById("edit-id").value;
  const rating = Number(document.getElementById("edit-rating").value);
  const comment = document.getElementById("edit-comment").value.trim() || null;
  try {
    await apiFetch(`${API_BASE_URL}/favoritos/${id}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ rating, comment }),
    });
    editModal.hide();
    showToast("Favorito atualizado!", "success");
    loadFavoritos();
  } catch (err) {
    showToast(`Não foi possível atualizar: ${err.message}`, "danger");
  }
});

// ---------------------------------------------------------------------------
// Remover favorito com confirmação (DELETE /favoritos/{id})
// ---------------------------------------------------------------------------

const deleteModalEl = document.getElementById("delete-modal");
const deleteModal = new bootstrap.Modal(deleteModalEl);
const deleteConfirmBtn = document.getElementById("delete-confirm-btn");
let pendingDeleteId = null;

favoritesListEl.addEventListener("click", (event) => {
  const btn = event.target.closest(".delete-favorite-btn");
  if (!btn) return;
  const favorito = favoritosById[btn.dataset.id];
  if (!favorito) return;
  pendingDeleteId = favorito.id;
  document.getElementById("delete-show-name").textContent = favorito.name;
  deleteModal.show();
});

deleteConfirmBtn.addEventListener("click", async () => {
  if (pendingDeleteId == null) return;
  try {
    await apiFetch(`${API_BASE_URL}/favoritos/${pendingDeleteId}`, { method: "DELETE" });
    deleteModal.hide();
    showToast("Favorito removido.", "success");
    pendingDeleteId = null;
    loadFavoritos();
  } catch (err) {
    showToast(`Não foi possível remover: ${err.message}`, "danger");
  }
});

function renderSearchCard(show) {
  const image = show.image && (show.image.medium || show.image.original);
  const genres = show.genres || [];
  const name = escapeHtml(show.name);
  const year = show.premiered ? show.premiered.slice(0, 4) : "";
  return `
    <div class="col">
      <article class="show-card">
        <div class="poster">
          <img src="${image || PLACEHOLDER_IMAGE}" alt="Capa de ${name}" loading="lazy">
          ${year ? `<span class="year-badge">${year}</span>` : ""}
        </div>
        <div class="show-info">
          <h3 class="show-title" title="${name}">${name}</h3>
          <div class="genre-chips">${genreBadges(genres)}</div>
          <button
            type="button"
            class="btn btn-sm btn-accent w-100 mt-auto add-favorite-btn"
            data-show-id="${show.id}"
            data-show-name="${name}"
            data-show-genres="${escapeHtml(genres.join(","))}"
            data-show-image="${image || ""}"
          >
            <i class="bi bi-plus-lg"></i> Favoritar
          </button>
        </div>
      </article>
    </div>
  `;
}
