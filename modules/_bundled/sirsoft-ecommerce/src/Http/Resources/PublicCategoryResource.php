<?php

namespace Modules\Sirsoft\Ecommerce\Http\Resources;

use App\Http\Resources\BaseApiResource;
use Illuminate\Http\Request;
use Modules\Sirsoft\Ecommerce\Models\Category;

/**
 * 공개 카테고리 API 리소스
 *
 * 프론트엔드 사용자 페이지에서 카테고리 트리를 표시하기 위한 리소스입니다.
 * 관리자용 CategoryResource와 달리, 공개에 필요한 최소 필드만 포함합니다.
 */
class PublicCategoryResource extends BaseApiResource
{
    /**
     * 공개 카테고리 트리를 중첩 ResourceCollection 없이 배열로 변환합니다.
     *
     * storefront는 모든 하위 카테고리를 한 번에 반환하므로 각 노드마다
     * ResourceCollection을 다시 생성할 필요가 없습니다. 공개 응답 계약에 포함된
     * 필드만 기존 PublicCategoryResource와 같은 형태로 조립합니다.
     *
     * @internal storefront optimized 경로 전용
     *
     * @param  iterable<int, Category>  $categories
     * @return array<int, array<string, mixed>>
     */
    public static function resolveTree(iterable $categories): array
    {
        $result = [];

        foreach ($categories as $category) {
            $item = [
                'id' => $category->id,
                'name' => $category->name,
                'name_localized' => $category->getLocalizedName(),
                'slug' => $category->slug,
                'depth' => $category->depth,
                'parent_id' => $category->parent_id,
                'products_count' => $category->products_count ?? 0,
            ];

            if ($category->relationLoaded('children')) {
                $item['children'] = self::resolveTree($category->children);
            }

            $result[] = $item;
        }

        return $result;
    }

    /**
     * 리소스를 배열로 변환합니다.
     *
     * @param  Request  $request  요청
     */
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'name' => $this->name,
            'name_localized' => $this->getLocalizedName(),
            'slug' => $this->slug,
            'depth' => $this->depth,
            'parent_id' => $this->parent_id,
            'products_count' => $this->products_count ?? 0,

            // 자식 카테고리 (재귀)
            'children' => $this->whenLoaded('children', function () {
                return PublicCategoryResource::collection($this->children);
            }),
        ];
    }
}
