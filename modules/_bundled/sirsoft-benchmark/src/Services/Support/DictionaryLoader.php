<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

class DictionaryLoader
{
    /** @var array<string, array<int, mixed>> */
    private array $cache = [];

    /**
     * @return array<int, mixed>
     */
    public function get(string $name): array
    {
        if (isset($this->cache[$name])) {
            return $this->cache[$name];
        }

        $path = dirname(__DIR__, 3)."/resources/dummy-dictionaries/{$name}.json";

        if (! is_file($path)) {
            return $this->cache[$name] = [];
        }

        $decoded = json_decode((string) file_get_contents($path), true);

        return $this->cache[$name] = is_array($decoded) ? array_values($decoded) : [];
    }
}
