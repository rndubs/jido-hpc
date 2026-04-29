import Config

# Runtime configuration. Read from environment so secrets stay
# out of source control. See plan.md for the security model.

if api_key = System.get_env("ANTHROPIC_API_KEY") do
  config :req_llm, anthropic_api_key: api_key
end

if api_key = System.get_env("OPENAI_API_KEY") do
  config :req_llm, openai_api_key: api_key
end

# Override path allowlist via colon-separated env var, e.g.
#   JIDO_HPC_PATH_ALLOWLIST="$HOME/projects:$SCRATCH/$USER"
if allowlist = System.get_env("JIDO_HPC_PATH_ALLOWLIST") do
  config :jido_hpc, path_allowlist: String.split(allowlist, ":", trim: true)
end

if autonomy = System.get_env("JIDO_HPC_AUTONOMY") do
  config :jido_hpc, autonomy: String.to_existing_atom(autonomy)
end
