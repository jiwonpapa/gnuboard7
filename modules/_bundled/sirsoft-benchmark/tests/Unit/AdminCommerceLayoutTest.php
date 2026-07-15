<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit;

use PHPUnit\Framework\TestCase;

class AdminCommerceLayoutTest extends TestCase
{
    public function test_admin_layout_exposes_commerce_workload_controls(): void
    {
        $path = dirname(__DIR__, 2).'/resources/layouts/admin/admin_benchmark_dashboard.json';
        $json = (string) file_get_contents($path);
        $layout = json_decode($json, true, flags: JSON_THROW_ON_ERROR);
        $form = $layout['init_actions'][0]['params']['form'];

        $this->assertSame('board', $form['workload_type']);
        $this->assertSame(10000, $form['total_products']);
        $this->assertSame(100, $form['image_pool_size']);
        $this->assertStringContainsString('쇼핑몰 상품 데이터', $json);
        $this->assertStringContainsString('form.total_products', $json);
        $this->assertStringContainsString('generated?.product_images', $json);
    }
}
