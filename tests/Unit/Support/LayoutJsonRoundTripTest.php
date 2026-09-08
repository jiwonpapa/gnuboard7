<?php

namespace Tests\Unit\Support;

use App\Http\Requests\Layout\UpdateLayoutContentRequest;
use App\Support\LayoutJson;
use Illuminate\Translation\ArrayLoader;
use Illuminate\Translation\Translator;
use Illuminate\Validation\Factory;
use PHPUnit\Framework\TestCase;

/** DB와 권한 검사를 대신하지 않는 JSON 표현 종류 회귀. */
final class LayoutJsonRoundTripTest extends TestCase
{
    public function test_merged_editor_nodes_restore_kinds_by_owner_and_id_without_restoring_deleted_values(): void
    {
        $original = LayoutJson::decode('{"components":[{"id":"own","name":"P","type":"basic","props":{},"future":{"empty":{},"deleted":"old"}}]}');
        $base = ['id' => 'parent', 'name' => 'Div', 'props' => [], '__source' => ['kind' => 'base', 'layout' => 'base']];
        $own = ['id' => 'own', 'name' => 'P', 'type' => 'basic', 'props' => [], 'future' => ['empty' => [], 'added' => 'new'], '__source' => ['kind' => 'route', 'layout' => 'child']];
        $extension = [...$own, '__source' => ['kind' => 'extension', 'layout' => 'foreign']];
        $actual = LayoutJson::editorResponse(['components' => [$base, $extension, $own]], $original, 'child');
        self::assertSame($base, $actual['components'][0]);
        self::assertSame($extension, $actual['components'][1]);
        self::assertInstanceOf(\stdClass::class, $actual['components'][2]['props']);
        self::assertInstanceOf(\stdClass::class, $actual['components'][2]['future']['empty']);
        self::assertArrayNotHasKey('deleted', $actual['components'][2]['future']);
        self::assertSame('new', $actual['components'][2]['future']['added']);
        self::assertSame($original, $actual['__editor']['original']);
    }

    public function test_validated_editor_content_preserves_object_and_list_kinds_after_source_masking(): void
    {
        $json = '{"version":"1.0.0","layout_name":"roundtrip","components":[{"id":"removed","name":"P","type":"basic","__source":{"kind":"extension"}},{"id":"kept","name":"P","type":"basic","text":"Before","props":{},"future":{"list":[],"object":{},"numeric":{"0":"zero"}}}]}';
        $request = new class(['content' => $json]) extends UpdateLayoutContentRequest
        {
            public function prepare(): void
            {
                $this->prepareForValidation();
            }
        };
        $request->prepare();
        $factory = new Factory(new Translator(new ArrayLoader, 'en'));
        $request->setValidator($factory->make($request->all(), ['content' => ['required', 'array']]));
        $stored = json_decode(json_encode($request->validated('content')), false);
        $this->assertCount(1, $stored->components);
        $this->assertInstanceOf(\stdClass::class, $stored->components[0]->props);
        $this->assertInstanceOf(\stdClass::class, $stored->components[0]->future->object);
        $this->assertSame([], $stored->components[0]->future->list);
        $this->assertInstanceOf(\stdClass::class, $stored->components[0]->future->numeric);
    }
}
