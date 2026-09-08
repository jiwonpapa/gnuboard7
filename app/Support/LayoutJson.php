<?php

namespace App\Support;

use stdClass;

/** PHP 내부 배열 API를 유지하면서 JSON 원본의 객체/목록 종류만 복원한다. */
final class LayoutJson
{
    /** @return array<string, mixed> */
    public static function decode(string $json): array
    {
        $value = json_decode($json, false, 512, JSON_THROW_ON_ERROR);

        return $value instanceof stdClass ? self::members($value) : [];
    }

    /** @return array<string|int, mixed> */
    private static function members(stdClass $value): array
    {
        $out = [];
        foreach ($value as $key => $item) {
            $out[$key] = self::convert($item);
        }

        return $out;
    }

    private static function convert(mixed $value): mixed
    {
        if ($value instanceof stdClass) {
            $members = self::members($value);

            // 빈 객체와 숫자 키 객체를 배열로 인코딩하지 않는다.
            return array_is_list($members) ? (object) $members : $members;
        }
        if (is_array($value)) {
            return array_map(self::convert(...), $value);
        }

        return $value;
    }

    /** 값·키를 원본에서 되살리지 않고, 검증/마스킹된 값의 컨테이너 종류만 복원한다. */
    public static function preserveKinds(mixed $current, mixed $original): mixed
    {
        if (! is_array($current)) {
            return $current;
        }
        $source = $original instanceof stdClass ? (array) $original : $original;
        if (! is_array($source)) {
            return $current;
        }
        foreach ($current as $key => $value) {
            if (array_key_exists($key, $source)) {
                $current[$key] = self::preserveKinds($value, $source[$key]);
            }
        }

        return $original instanceof stdClass ? (object) $current : $current;
    }

    /**
     * 병합/확장 처리가 끝난 편집 응답에서 해당 원본 소유 노드의 JSON 종류를 복원한다.
     * 부모·확장 노드의 값/출처나 트리 구조를 바꾸지 않는다.
     *
     * @param  array<string, mixed>  $layout
     * @param  array<string, mixed>  $original
     * @return array<string, mixed>
     */
    public static function editorResponse(array $layout, array $original, string $layoutName): array
    {
        $nodes = [];
        self::indexNodes($original, $nodes);
        $visit = function (mixed $value) use (&$visit, $nodes, $layoutName): mixed {
            if (! is_array($value)) {
                return $value;
            }
            $id = $value['id'] ?? null;
            if (is_string($id) && isset($nodes[$id]) && ($value['__source']['kind'] ?? null) === 'route'
                && ($value['__source']['layout'] ?? null) === $layoutName) {
                // 자식은 자신의 ID로 대응한다. 병합 후 배열 위치 변경을 원본 위치로 오인하지 않는다.
                foreach ($value as $key => $item) {
                    if ($key !== 'children' && array_key_exists($key, $nodes[$id])) {
                        $value[$key] = self::preserveKinds($item, $nodes[$id][$key]);
                    }
                }
            }
            foreach ($value as $key => $item) {
                $value[$key] = $visit($item);
            }

            return $value;
        };
        $layout = $visit($layout);
        $layout['__editor']['original'] = $original;

        return $layout;
    }

    /** @param array<string, array<string, mixed>> $nodes */
    private static function indexNodes(mixed $value, array &$nodes): void
    {
        if (! is_array($value)) {
            return;
        }
        if (isset($value['id'], $value['name'], $value['type']) && is_string($value['id'])) {
            $nodes[$value['id']] = $value;
        }
        foreach ($value as $item) {
            self::indexNodes($item, $nodes);
        }
    }
}
