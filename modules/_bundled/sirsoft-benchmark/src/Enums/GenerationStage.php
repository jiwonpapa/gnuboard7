<?php

namespace Modules\Sirsoft\Benchmark\Enums;

enum GenerationStage: string
{
    case Planning = 'planning';
    case Users = 'users';
    case Boards = 'boards';
    case Posts = 'posts';
    case Comments = 'comments';
    case Syncing = 'syncing';
    case ImagePool = 'image_pool';
    case Categories = 'categories';
    case Brands = 'brands';
    case Products = 'products';
    case Verifying = 'verifying';
    case Resetting = 'resetting';
    case Completed = 'completed';
}
